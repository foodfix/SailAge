#!/usr/bin/env python3
"""Hi-res side-view source pass — the multi-angle token pipeline, stage 1.

For every ship type: crop the DETERMINISTIC generator's w cell (the
direction ground truth produced by `model_pass.py redraft`) out of
``model_raw/drafts/sheet_<ship>.png`` as the 512x512 reference, rebuild the
canonical hull w-pose prompt via ``chain.reconstruct_original``, reuse the
hull's kept re-roll seed, and
POST TheNoise ``:8001/edit`` ``{"image","prompt","seed"}`` — the validated
draft-as-reference restyle (80-* §4.8). The raw ~1MP PNG (flat chroma-key
green background) is written gitignored to
``model_raw/sideviews/<ship>_side.png`` plus a ``sideviews.json`` manifest
(prompt, seed, source, bytes, size, seconds, corner-green + opaque
sanity). NO rembg, NO snap: this output is the ComfyUI multi-angle LoRA's
INPUT (the identity anchor), not a token — all five shipped views,
including the elevated w, are generated downstream by ``angle_pass.py``
and size-normalized there. Raw model output is never committed
(90-* §9.2).

Usage:
  python3 tools/sideview_pass.py run [ship ...]   # default: all 16
  python3 tools/sideview_pass.py status
"""

from __future__ import annotations

import io
import json
import os
import sys
import time
import zlib

REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
sys.path.insert(0, os.path.join(REPO, "tools", "model_studio"))
sys.path.insert(0, os.path.join(REPO, "tools"))

import chain  # noqa: E402 — studio chain (generate / reconstruct / writes)

OUT_DIR = os.path.join(REPO, "tools", "ui_art", "model_raw", "sideviews")
MANIFEST = os.path.join(OUT_DIR, "sideviews.json")
SHEET_CELL_PX = 512
# EMBEDDED_DRIVER SHEET_CELLS["w"] — top-left of the w cell on the sheet.
W_CELL_BOX = (64, 64, 64 + SHEET_CELL_PX, 64 + SHEET_CELL_PX)
# Pixel-art style clause appended verbatim to every stage-1 prompt
# (80-* §4.8, "Pixel-art read for the 64 grid" amendment, 2026-11-06):
# fine-textured 1024² renders lose rigging/windows/gunports in the
# 64-grid majority vote — the side view is the ComfyUI identity
# reference, so all five branches inherit the style from it.
PIXEL_ART_CLAUSE = (
    "Crisp pixel art sprite: big chunky square pixels, flat color "
    "fills, strong dark outline around the sprite, limited palette, "
    "bold silhouette readable at 64×64 size, no thin rigging lines, "
    "no fine surface texture, no anti-aliasing, no dithering.")


def _ships() -> list[str]:
    with open(os.path.join(REPO, "data", "ship_types.json"),
              encoding="utf-8") as fh:
        return [s["id"] for s in json.load(fh)["ship_types"]]


def _w_cell_png(ship: str) -> bytes:
    """512x512 w-cell crop of the deterministic sheet draft, as PNG bytes."""
    from PIL import Image  # noqa: PLC0415 — same dep the driver uses
    path = os.path.join(REPO, "tools", "ui_art", "model_raw", "drafts",
                        f"sheet_{ship}.png")
    with Image.open(path) as im:
        cell = im.crop(W_CELL_BOX)
    buf = io.BytesIO()
    cell.save(buf, format="PNG")
    return buf.getvalue()


def _w_record(ship: str) -> dict | None:
    path = os.path.join(REPO, "tools", "ui_art", "model_raw",
                        "progress.json")
    try:
        with open(path, encoding="utf-8") as fh:
            jobs = json.load(fh).get("jobs", {})
    except (OSError, ValueError):
        return None
    return jobs.get(f"hull_{ship}_w")


def _seed_for(ship: str, rec: dict | None) -> int:
    if rec:
        kept = (rec.get("reroll") or {}).get("kept_seed")
        if isinstance(kept, int) and kept >= 0:
            return kept
        if isinstance(rec.get("seed"), int) and rec["seed"] >= 0:
            return rec["seed"]
    return zlib.crc32(ship.encode("utf-8")) % 100_000_000 + 1


def _corner_green(w: int, h: int, px: list[list]) -> bool:
    """The four 16x16 corners must be chroma green (g dominant, r/b low).
    Pixels are validate_data-style hex strings ("#rrggbb") or None."""
    for cx, cy in ((0, 0), (w - 16, 0), (0, h - 16), (w - 16, h - 16)):
        for y in range(cy, cy + 16):
            for x in range(cx, cx + 16):
                p = px[y][x]
                if p is None:
                    return False
                r = int(p[1:3], 16)
                g = int(p[3:5], 16)
                b = int(p[5:7], 16)
                if not (g >= 160 and r <= 120 and b <= 120):
                    return False
    return True


def _opaque_pct(w: int, h: int, px: list[list]) -> float:
    n = sum(1 for row in px for p in row if p is not None)
    return round(100.0 * n / (w * h), 1)


def run(ships: list[str]) -> None:
    chain.init(REPO)
    os.makedirs(OUT_DIR, exist_ok=True)
    manifest: dict = {}
    if os.path.exists(MANIFEST):
        with open(MANIFEST, encoding="utf-8") as fh:
            manifest = json.load(fh)
    for i, ship in enumerate(ships, 1):
        print(f"[sideview {i}/{len(ships)}] {ship}", flush=True)
        rec = _w_record(ship)
        prompt, source = chain.reconstruct_original(
            f"hull_{ship}_w", REPO, rec)
        prompt = f"{prompt} {PIXEL_ART_CLAUSE}"
        source = f"{source}+pixel_art_clause(80-*4.8)"
        seed = _seed_for(ship, rec)
        draft = _w_cell_png(ship)
        t0 = time.time()
        gen = chain.generate(draft, prompt, seed)  # validated retry x2
        w, h, px = chain.decode_rgba(gen)
        entry = {
            "prompt": prompt,
            "prompt_source": source,
            "seed": seed,
            "reference": f"drafts/sheet_{ship}.png w-cell",
            "gen_size": [w, h],
            "gen_bytes": len(gen),
            "corner_green": _corner_green(w, h, px),
            "opaque_pct": _opaque_pct(w, h, px),
            "seconds": round(time.time() - t0, 1),
        }
        chain.atomic_write(os.path.join(OUT_DIR, f"{ship}_side.png"), gen)
        manifest[ship] = entry
        chain.atomic_write(MANIFEST,
                           json.dumps(manifest, indent=1,
                                      ensure_ascii=False).encode("utf-8"))
        print(f"    {w}x{h} {len(gen)}B seed={seed} "
              f"green={entry['corner_green']} "
              f"opaque={entry['opaque_pct']}% {entry['seconds']}s",
              flush=True)
    print(f"[sideview] manifest -> {MANIFEST}", flush=True)


def status() -> None:
    if not os.path.exists(MANIFEST):
        print("no manifest yet")
        return
    with open(MANIFEST, encoding="utf-8") as fh:
        m = json.load(fh)
    for ship, e in m.items():
        print(f"{ship:18s} {e['gen_size'][0]}x{e['gen_size'][1]} "
              f"seed={e['seed']} green={e['corner_green']} "
              f"opaque={e['opaque_pct']}% {e['seconds']}s "
              f"prompt={e['prompt_source']}")
    print(f"{len(m)} ships")


def main() -> None:
    cmd = sys.argv[1] if len(sys.argv) > 1 else "status"
    if cmd == "run":
        run(sys.argv[2:] or _ships())
    elif cmd == "status":
        status()
    else:
        raise SystemExit(__doc__)


if __name__ == "__main__":
    main()
