#!/usr/bin/env python3
"""Top-down hull review sheet builder (80-* §4.8 2026-11-07).

One review sheet per run: for every generated ship, a row of the 8 runtime
rotations (PIL NEAREST — the same resampling family the game pins) around
the raw north token, labeled with the ship id + tier canvas size. No API
contact; output is a gitignored review artifact (art_review/).

Usage:
  python3 tools/preview_topdown.py [--out art_review/topdown_review.png]
"""
from __future__ import annotations

import json
import os
import sys

REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
RAW = os.path.join(REPO, "tools", "ui_art", "model_raw", "pixellab_topdown")
OUT_DEFAULT = os.path.join(REPO, "art_review", "topdown_review.png")

# The pinned rotation map (80-* §4.8 2026-11-07; clockwise, screen y-down)
ROTATIONS = (("n", 0), ("ne", 45), ("e", 90), ("se", 135),
             ("s", 180), ("sw", 225), ("w", 270), ("nw", 315))
TIER_SIZE = {1: 32, 2: 48, 3: 64}
CELL = 96          # on-sheet cell px per rotation (tokens draw 1:1 inside)
BG = (22, 68, 110, 255)     # SEA — the wake review precedent
FG = (223, 240, 244, 255)   # FOAM labels


def main() -> None:
    out = sys.argv[sys.argv.index("--out") + 1] if "--out" in sys.argv \
        else OUT_DEFAULT
    manifest = {}
    mpath = os.path.join(RAW, "pixellab_topdown.json")
    if os.path.isfile(mpath):
        with open(mpath, encoding="utf-8") as fh:
            manifest = json.load(fh)
    tiers = {}
    with open(os.path.join(REPO, "data", "ship_types.json"),
              encoding="utf-8") as fh:
        tiers = {s["id"]: int(s["tier"])
                 for s in json.load(fh)["ship_types"]}

    from PIL import Image, ImageDraw  # noqa: PLC0415

    ships = sorted(set(manifest) |
                   {n for n in os.listdir(RAW)
                    if os.path.isdir(os.path.join(RAW, n))})
    rows = []
    for ship in ships:
        p = os.path.join(RAW, ship, "snapped", "north.png")
        if not os.path.isfile(p):
            continue
        rows.append((ship, Image.open(p).convert("RGBA")))
    if not rows:
        raise SystemExit(f"no snapped north tokens under {RAW} — run "
                         "pixellab_pass --topdown run + snap first")

    label_h = 14
    sheet = Image.new("RGBA", (CELL * len(ROTATIONS) + 8,
                               (CELL + label_h + 4) * len(rows) + 8), BG)
    draw = ImageDraw.Draw(sheet)
    for i, (ship, img) in enumerate(rows):
        y0 = 4 + i * (CELL + label_h + 4)
        s = img.size[0]
        draw.text((6, y0 + CELL - 2),
                  f"{ship} · tier {tiers.get(ship, '?')} · {s}x{s}", fill=FG)
        for j, (_d, deg) in enumerate(ROTATIONS):
            rot = img.rotate(-deg, resample=Image.NEAREST, expand=False)
            cx = 4 + j * CELL + (CELL - s) // 2
            cy = y0 + (CELL - s) // 2
            sheet.alpha_composite(rot, (cx, cy))
        draw.line((0, y0 + CELL + label_h, sheet.w, y0 + CELL + label_h),
                  fill=(0, 0, 0, 90), width=1)
    os.makedirs(os.path.dirname(out), exist_ok=True)
    sheet.save(out)
    print(f"preview_topdown: {len(rows)} ships x {len(ROTATIONS)} rotations"
          f" -> {out} ({sheet.w}x{sheet.h})")


if __name__ == "__main__":
    main()
