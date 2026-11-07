#!/usr/bin/env python3
"""Waterline VFX preview sheets — 16 ships x directions x {player, npc}.

Dev-only review artifact for the 80-* §4.8 2026-11-07 waterline family
(gitignored under tools/ui_art/model_raw/pixellab_vfx/preview/, never
committed). Composites, per ship and direction, the exact runtime
sandwich: sea tile -> behind (player only) -> the shared hull token ->
front, placed at feet_anchor + offset from the pack manifest, still
frame 0 for the sheets and the full 8-frame loop for the motion GIFs.
No API contact, no assets/ui changes — review pixels only.

Usage:
  python3 tools/preview_waterline.py [dir ...]   # default: e ne
"""
from __future__ import annotations

import hashlib
import json
import os
import sys
import zipfile

from PIL import Image, ImageDraw

REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import pixellab_vfx_pass as vfx  # noqa: E402 — _anchor_in_sprite, OUT_DIR

RAW = vfx.OUT_DIR
OUT = os.path.join(RAW, "preview")  # canonical preview dir (v1 + v2)
SEA_TILE = os.path.join(REPO, "assets", "ui", "terrain", "terrain_sea_0.png")
TOKEN_FMT = "assets/ui/tokens/hull_{}_{}.png"
UP = 4          # sheet upscale (nearest)
MARGIN = 6      # 1x px of sea around every composite
LABEL_W, HEADER_H, TITLE_H = 150, 26, 30
STILL_FRAME = 0
GIF_SHIPS = ("galleass", "sloop")   # largest + smallest footprint


def _ships() -> list[str]:
    with open(os.path.join(REPO, "data", "ship_types.json"),
              encoding="utf-8") as fh:
        return [s["id"] for s in json.load(fh)["ship_types"]]


def _load_dir(dir_id: str, raw_root: str) -> dict:
    """Per-direction geometry + frames from the game pack, plus the
    feet-in-box anchor (template match, bbox fallback under 0.15)."""
    ddir = os.path.join(raw_root, dir_id)
    packs = sorted(f for f in os.listdir(ddir) if f.endswith("-game.zip")) \
        if os.path.isdir(ddir) else []
    if not packs:
        raise SystemExit(f"missing game pack for {dir_id}: {ddir}")
    pack = os.path.join(ddir, packs[0])
    with zipfile.ZipFile(pack) as zf:
        m = json.loads(zf.read("manifest.json"))
        clips = {c["name"]: c for c in m["clips"]}

        def clip_frames(name: str):
            c = clips[name]
            fw, fh = c["frame"]["w"], c["frame"]["h"]
            img = Image.open(zf.open(c["sheets"][0]["file"])).convert("RGBA")
            cols = c["sheets"][0]["columns"]

            def frame(i: int) -> Image.Image:
                cx, cy = (i % cols) * fw, (i // cols) * fh
                return img.crop((cx, cy, cx + fw, cy + fh))
            return {"offset": (c["offset"]["x"], c["offset"]["y"]),
                    "size": (fw, fh), "frames": c["frames"], "draw": frame}

        anchor = vfx._anchor_in_sprite(dir_id, pack)
        if anchor["match_rate"] < 0.15:
            # bbox fallback: feet = token bbox bottom-center (flagged)
            sp = Image.open(vfx._sprite_path(dir_id)).convert("RGBA")
            bx = sp.getbbox()
            anchor = {"x": (bx[0] + bx[2]) // 2, "y": bx[3],
                      "match_rate": anchor["match_rate"],
                      "frame_bbox": anchor["frame_bbox"],
                      "method": "bbox-fallback"}
        else:
            anchor["method"] = "template-match"
        return {"anchor": anchor, "behind": clip_frames("behind"),
                "front": clip_frames("front"),
                "fps": m["fps"], "frame_ms": m["frame_ms"],
                "loop": m["loop"], "canvas": m["canvas"]}


def _stage_geometry(d: dict) -> dict:
    """Fixed per-direction stage: union of the three layer rects with the
    ship box at (0,0), plus MARGIN — one stage size for the whole grid."""
    rects = [((0, 0), (64, 64)),
             (d["behind"]["offset"], d["behind"]["size"]),
             (d["front"]["offset"], d["front"]["size"])]
    x0 = min(o[0] for o, _ in rects) - MARGIN
    y0 = min(o[1] for o, _ in rects) - MARGIN
    x1 = max(o[0] + s[0] for o, s in rects) + MARGIN
    y1 = max(o[1] + s[1] for o, s in rects) + MARGIN
    return {"origin": (-x0, -y0), "size": (x1 - x0, y1 - y0)}


def _cell(d: dict, ship: str, player: bool, frame_i: int) -> Image.Image:
    g = d["_stage"]
    sea = Image.open(SEA_TILE).convert("RGBA")
    stage = Image.new("RGBA", g["size"])
    for ty in range(0, g["size"][1], sea.height):
        for tx in range(0, g["size"][0], sea.width):
            stage.paste(sea, (tx, ty))
    box = g["origin"]
    feet = (box[0] + d["anchor"]["x"], box[1] + d["anchor"]["y"])
    # 2026-11-07 scope: BOTH sheets render for every hull token — player
    # and NPC alike (the front-only NPC rule died with the v1 rings).
    bt = (feet[0] + d["behind"]["offset"][0],
          feet[1] + d["behind"]["offset"][1])
    stage.alpha_composite(d["behind"]["draw"](frame_i), bt)
    ship_img = Image.open(os.path.join(REPO, TOKEN_FMT.format(ship, d["dir"]))
                          ).convert("RGBA")
    stage.alpha_composite(ship_img, box)
    ft = (feet[0] + d["front"]["offset"][0],
          feet[1] + d["front"]["offset"][1])
    stage.alpha_composite(d["front"]["draw"](frame_i), ft)
    return stage.resize((stage.width * UP, stage.height * UP), Image.NEAREST)


def _sha(path: str) -> str:
    return hashlib.sha256(open(path, "rb").read()).hexdigest()


def main() -> None:
    import argparse  # noqa: PLC0415
    ap = argparse.ArgumentParser(
        description="Waterline VFX preview sheets (review-only artifact)")
    ap.add_argument("dirs", nargs="*", help=f"dir ids, subset of {vfx.DIRS}")
    ap.add_argument("--raw", default=RAW,
                    help=f"raw root holding <dir>/waterline-*-game.zip "
                         f"(default {RAW})")
    ap.add_argument("--out-name", help="output name suffix (default the "
                                       "dir id) — v2 variants pass e.g. "
                                       "v2_e_lite")
    args = ap.parse_args()
    dirs = [a for a in args.dirs if a in vfx.DIRS] or ["e", "ne"]
    unknown = [a for a in args.dirs if a not in vfx.DIRS]
    if unknown:
        raise SystemExit(f"unknown dirs: {unknown}")
    os.makedirs(OUT, exist_ok=True)
    ships = _ships()
    notes: dict = {"dirs": {}, "sheets": {}, "gifs": {}, "warnings": []}

    for dir_id in dirs:
        tag = args.out_name or dir_id
        d = _load_dir(dir_id, args.raw)
        d["dir"] = dir_id
        d["_stage"] = _stage_geometry(d)
        notes["dirs"][dir_id] = {
            "anchor": d["anchor"], "canvas": d["canvas"],
            "fps": d["fps"], "frame_ms": d["frame_ms"],
            "behind": {k: d["behind"][k] for k in ("offset", "size",
                                                   "frames")},
            "front": {k: d["front"][k] for k in ("offset", "size",
                                                 "frames")},
            "stage": d["_stage"]["size"],
        }
        cw, ch = d["_stage"]["size"][0] * UP, d["_stage"]["size"][1] * UP
        # --- contact sheet: rows = ships, cols = player | npc ---
        sheet = Image.new("RGBA", (LABEL_W + 2 * cw + 24,
                                   TITLE_H + HEADER_H + len(ships) * (ch + 6)
                                   + 8), (32, 32, 32, 255))
        draw = ImageDraw.Draw(sheet)
        draw.text((8, 8), f"waterline {tag}  —  still frame "
                          f"{STILL_FRAME}, sea = terrain_sea_0",
                  fill=(230, 230, 230))
        hy = TITLE_H
        draw.text((LABEL_W + 8, hy + 6), "PLAYER (back + hull + foam)",
                  fill=(240, 210, 120))
        draw.text((LABEL_W + cw + 16, hy + 6), "NPC (back + hull + foam)",
                  fill=(170, 210, 240))
        if d["anchor"]["method"] == "bbox-fallback":
            draw.text((LABEL_W + cw + 16, hy + 18),
                      "anchor FALLBACK — verify alignment!",
                      fill=(250, 120, 90))
        for r, ship in enumerate(ships):
            y = hy + HEADER_H + r * (ch + 6)
            draw.text((8, y + ch // 2 - 6), ship, fill=(220, 220, 220))
            for c, player in ((0, True), (1, False)):
                cell = _cell(d, ship, player, STILL_FRAME)
                sheet.alpha_composite(cell, (LABEL_W + 8 + c * (cw + 8),
                                             y))
                fa = d["front"]["draw"](STILL_FRAME)
                opaque = sum(1 for p in fa.getdata() if p[3] > 0)
                if opaque == 0:
                    notes["warnings"].append(
                        f"{dir_id}/{ship}: front frame {STILL_FRAME} "
                        "is fully transparent")
        out_png = os.path.join(OUT, f"sheet_waterline_{tag}.png")
        sheet.save(out_png)
        notes["sheets"][os.path.basename(out_png)] = _sha(out_png)
        print(f"sheet -> {out_png} ({sheet.width}x{sheet.height})",
              flush=True)
        # --- motion GIFs (player look), largest + smallest ship ---
        for ship in GIF_SHIPS:
            frames = [_cell(d, ship, True, i) for i in
                      range(d["behind"]["frames"])]
            out_gif = os.path.join(OUT, f"motion_{tag}_{ship}.gif")
            frames[0].save(out_gif, save_all=True, append_images=frames[1:],
                           duration=d["frame_ms"], loop=0)
            notes["gifs"][os.path.basename(out_gif)] = _sha(out_gif)
            print(f"gif   -> {out_gif}", flush=True)

    notes_path = os.path.join(
        OUT, f"preview_notes_{args.out_name or 'default'}.json")
    with open(notes_path, "w", encoding="utf-8") as fh:
        json.dump(notes, fh, indent=1, sort_keys=True)
        fh.write("\n")
    for w in notes["warnings"]:
        print(f"WARN {w}")
    print(f"notes -> {notes_path}")


if __name__ == "__main__":
    main()
