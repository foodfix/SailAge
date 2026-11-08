#!/usr/bin/env python3
"""Icon review sheet builder (80-* §4.8, the 2026-11-08 icon amendment).

One review sheet per run: for every snapped icon, a row of the raw 64
canvas beside its halved 32 inline preview (the exact 2:1 nearest halving
the ingest pins), both on the PANEL_BG recess, labeled with the icon id +
the first prompt clause. No API contact; output is a gitignored review
artifact (art_review/).

Usage:
  python3 tools/preview_icons.py [--out art_review/icons_review.png]
                                 [--only id ...]
"""
from __future__ import annotations

import json
import os
import sys

from PIL import Image  # noqa: PLC0415

REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
RAW = os.path.join(REPO, "tools", "ui_art", "model_raw", "pixellab_icons")
OUT_DEFAULT = os.path.join(REPO, "art_review", "icons_review.png")

RECESS = (28, 34, 48, 255)    # PANEL_BG — the icon recess/background fill
RECESS_LO = (18, 23, 36, 255)  # ICON_BG_LO — the 8px checker step
FG = (232, 230, 223, 255)     # TEXT — labels
CELL = 72                     # on-sheet cell px (the 64 draws 1:1 inside)
HALF = 36                     # the halved 32 draws 1:1 inside


def _checker(w: int, h: int) -> Image.Image:  # noqa: F821
    img = Image.new("RGBA", (w, h))
    px = img.load()
    for y in range(h):
        for x in range(w):
            px[x, y] = RECESS if ((x // 8) + (y // 8)) % 2 == 0 else RECESS_LO
    return img


def main() -> None:
    args = sys.argv[1:]
    out = args[args.index("--out") + 1] if "--out" in args else OUT_DEFAULT
    only = args[args.index("--only") + 1:] if "--only" in args else []

    manifest = {}
    mpath = os.path.join(RAW, "pixellab_icons.json")
    if os.path.isfile(mpath):
        with open(mpath, encoding="utf-8") as fh:
            manifest = json.load(fh)

    from PIL import ImageDraw  # noqa: PLC0415

    ids = sorted(set(manifest) |
                 {n for n in os.listdir(RAW)
                  if os.path.isdir(os.path.join(RAW, n))})
    if only:
        ids = [i for i in ids if i in set(only)]
    rows = []
    for iid in ids:
        p = os.path.join(RAW, iid, "snapped", "icon.png")
        if not os.path.isfile(p):
            p = os.path.join(RAW, iid, "icon.png")
        if not os.path.isfile(p):
            continue
        img = Image.open(p).convert("RGBA")
        if img.size != (64, 64):
            print(f"  {iid}: skipped — {img.size} != 64x64")
            continue
        # the ingest's halving, pinned: out(x, y) = src(2x, 2y)
        half = img.resize((32, 32), Image.NEAREST)
        rows.append((iid, manifest.get(iid, {}).get("description", ""), img,
                     half))
    if not rows:
        raise SystemExit(f"no snapped icons under {RAW} — run "
                         "pixellab_pass --icons run + snap first")

    label_h = 14
    pad = 10
    W = pad + CELL + 8 + HALF + pad + 340
    H = pad + len(rows) * (label_h + CELL + pad)
    sheet = Image.new("RGBA", (W, H), RECESS)
    draw = ImageDraw.Draw(sheet)
    for i, (iid, desc, img, half) in enumerate(rows):
        y = pad + i * (label_h + CELL + pad)
        head = desc.split(",")[0] if desc else ""
        draw.text((pad, y), f"{iid}  ·  {head[:46]}", fill=FG)
        y += label_h
        sheet.alpha_composite(_checker(CELL, CELL), (pad, y))
        sheet.alpha_composite(img, (pad, y))
        sheet.alpha_composite(_checker(HALF, HALF), (pad + CELL + 8, y))
        sheet.alpha_composite(half, (pad + CELL + 8, y))
        draw.rectangle([pad - 1, y - 1, pad + CELL, y + CELL],
                       outline=(70, 84, 104, 255))
        draw.rectangle([pad + CELL + 7, y - 1, pad + CELL + 8 + HALF,
                        y + HALF], outline=(70, 84, 104, 255))
    os.makedirs(os.path.dirname(out), exist_ok=True)
    sheet.save(out)
    print(f"preview_icons: {len(rows)} icons -> {out}")


if __name__ == "__main__":
    main()
