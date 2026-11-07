#!/usr/bin/env python3
"""Wake VFX preview sheet — the 16 per-ship north wakes (§4.8 2026-11-08,
per-ship wake revision).

Dev-only review artifact (gitignored under
tools/ui_art/model_raw/pixellab_vfx/v6/preview/, never committed).
Composites, per ship, the exact runtime single-layer sandwich: sea tile →
the ship's raw wake frame 0 UNDER the ship's own north token, placed at
anchor_sprite + offset from the v6 pass manifest. No API contact, no
assets/ui changes — review pixels only.

Usage:
  python3 tools/preview_wake_v6.py [ship ...]   # default: all 16
"""
from __future__ import annotations

import json
import os
import sys
import zipfile

from PIL import Image, ImageDraw

REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import pixellab_vfx_pass as vfx  # noqa: E402 — SHIPS, V6_OUT_DIR

RAW = vfx.V6_OUT_DIR
OUT = os.path.join(RAW, "preview")
SEA_TILE = os.path.join(REPO, "assets", "ui", "terrain", "terrain_sea_0.png")
TOKEN_FMT = "assets/ui/tokens/hull_{}.png"
UP = 4          # sheet upscale (nearest)
MARGIN = 6      # 1x px of sea around every composite
CELL_W, CELL_H, LABEL_W, HEADER_H, TITLE_H = 200, 180, 150, 26, 30


def _ships() -> list[str]:
    with open(os.path.join(REPO, "data", "ship_types.json"),
              encoding="utf-8") as fh:
        return sorted(s["id"] for s in json.load(fh)["ship_types"])


def _pack_geometry(ship: str) -> dict:
    """Frame 0 + placement geometry out of the ship's raw game pack."""
    ddir = os.path.join(RAW, ship)
    packs = sorted(f for f in os.listdir(ddir) if f.endswith("-game.zip")) \
        if os.path.isdir(ddir) else []
    if not packs:
        raise SystemExit(f"missing game pack for {ship}: {ddir}")
    with zipfile.ZipFile(os.path.join(ddir, packs[0])) as zf:
        m = json.loads(zf.read("manifest.json"))
        clip = next(c for c in m["clips"] if c["name"] == "behind")
        fw, fh = clip["frame"]["w"], clip["frame"]["h"]
        sheet = Image.open(zf.open(clip["sheets"][0]["file"])).convert(
            "RGBA")
    frame = sheet.crop((0, 0, fw, fh))
    with open(os.path.join(RAW, "pixellab_vfx.json"), encoding="utf-8") as fh:
        rec = json.load(fh).get(ship, {})
    return {
        "frame": frame,
        "offset": clip.get("offset", {}),
        "anchor": rec.get("anchor_sprite", {}),
        "token": Image.open(
            os.path.join(REPO, TOKEN_FMT.format(ship))).convert("RGBA"),
    }


def main() -> None:
    ships = _fx_ships_or_all() if not sys.argv[1:] else sys.argv[1:]
    cols = 4
    rows = (len(ships) + cols - 1) // cols
    cell_pw, cell_ph = CELL_W * UP, CELL_H * UP
    label_pw = LABEL_W * UP
    width = label_pw + cols * cell_pw + MARGIN * UP
    height = (TITLE_H + rows * HEADER_H) * UP // UP + TITLE_H \
        + rows * cell_ph + MARGIN * UP
    sheet = Image.new("RGBA", (width, height), (18, 32, 52, 255))
    draw = ImageDraw.Draw(sheet)
    draw.text((8, 8), "wake v6 review — per-ship north wakes, frame 0, "
              "runtime placement", fill=(220, 230, 240))
    sea = Image.open(SEA_TILE).convert("RGBA")
    for index, ship in enumerate(ships):
        g = _pack_geometry(ship)
        col, row = index % cols, index // cols
        x0 = label_pw + col * cell_pw
        y0 = TITLE_H + row * (HEADER_H + cell_ph)
        draw.text((x0 + 4, y0 + 2), ship, fill=(240, 240, 240))
        # the sea backdrop (one tile, nearest-upscaled over the cell)
        cell = Image.new("RGBA", (cell_pw, cell_ph))
        for ty in range(0, cell_ph, sea.height * UP):
            for tx in range(0, cell_pw, sea.width * UP):
                cell.alpha_composite(sea.resize(
                    (sea.width * UP, sea.height * UP), Image.NEAREST),
                    (tx, ty))
        s = g["token"].width * UP
        box_x = (cell_pw - s) // 2
        box_y = (cell_ph - s) // 2
        frame = g["frame"].resize(
            (g["frame"].width * UP, g["frame"].height * UP), Image.NEAREST)
        off, anc = g["offset"], g["anchor"]
        # sheet top-left = token box top-left + (anchor + offset); the
        # box coords are already upscaled, the table coords are 1x
        cell.alpha_composite(frame, (
            box_x + int((float(anc.get("x", 0.0))
                         + float(off.get("x", 0.0))) * UP),
            box_y + int((float(anc.get("y", 0.0))
                         + float(off.get("y", 0.0))) * UP)))
        cell.alpha_composite(
            g["token"].resize((s, s), Image.NEAREST), (box_x, box_y))
        sheet.alpha_composite(cell, (x0, y0 + HEADER_H))
    os.makedirs(OUT, exist_ok=True)
    out_png = os.path.join(OUT, "wake_v6_review.png")
    sheet.save(out_png)
    print(f"preview sheet -> {out_png}")


def _fx_ships_or_all() -> list[str]:
    return [s for s in vfx.SHIPS]


if __name__ == "__main__":
    main()
