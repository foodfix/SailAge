#!/usr/bin/env python3
"""Pinned-node double-run byte-identity fixture checker for tools/yoyopixel/render.js.

Renders the committed sample declarations under ``fixtures/decls/`` twice
into fresh temporary directories with the pinned node, then verifies:

1. run 1 vs run 2 -- byte-identical (engine + zlib determinism);
2. run 1 vs ``fixtures/expected/`` -- byte-identical to the committed
   fixture PNGs (a drift in node or engine behavior goes red);
3. every output is a structurally valid PNG (chunk walk, CRC32 per chunk,
   IHDR fields, filter-type-0 scanlines, IDAT inflates to the exact size).

Exit 0 only when all three hold for every declaration.

Usage::

    python3 tools/yoyopixel/fixture_check.py            # check
    python3 tools/yoyopixel/fixture_check.py --regen    # rewrite fixtures/expected/

``--regen`` re-renders the committed declarations in place (writing
``fixtures/expected/*.png``); run the checker afterwards to confirm.

Node is pinned to v24.16.0 (docs/IMPLEMENT-Phase10.md correction 10);
the checker refuses to run under any other version. Stdlib only
(Python 3.10+).
"""

from __future__ import annotations

import argparse
import struct
import subprocess
import sys
import tempfile
import zlib
from pathlib import Path

NODE_PIN = "v24.16.0"
ROOT = Path(__file__).resolve().parent
FIXTURES = ROOT / "fixtures"
DECLS = FIXTURES / "decls"
EXPECTED = FIXTURES / "expected"

PNG_SIGNATURE = b"\x89PNG\r\n\x1a\n"
COLOR_TYPES = {0: "grayscale", 2: "rgb", 3: "indexed", 4: "gray+alpha", 6: "rgba"}
CHANNELS = {0: 1, 2: 3, 3: 1, 4: 2, 6: 4}


def fail(msg: str) -> None:
    print(msg, file=sys.stderr)


def node_version() -> str:
    try:
        r = subprocess.run(["node", "--version"], capture_output=True, text=True)
    except FileNotFoundError:
        fail("fixture_check: node not found on PATH")
        sys.exit(2)
    if r.returncode != 0:
        fail(f"fixture_check: cannot run node: {r.stderr.strip()}")
        sys.exit(2)
    return r.stdout.strip()


def verify_png_structure(data: bytes, name: str) -> tuple[int, int, int]:
    """Walk chunks / check CRCs / inflate IDAT. Returns (w, h, color_type)."""
    def bad(msg: str) -> None:
        raise ValueError(f"{name}: {msg}")

    if not data.startswith(PNG_SIGNATURE):
        bad("missing PNG signature")
    pos = len(PNG_SIGNATURE)
    ihdr: tuple[int, int, int] | None = None
    idat = bytearray()
    seen = set()
    while pos < len(data):
        if pos + 8 > len(data):
            bad("truncated chunk header")
        (length, ctype) = struct.unpack(">I4s", data[pos : pos + 8])
        ctype_s = ctype.decode("ascii", "replace")
        if length > 0x7FFF_FFFF:
            bad(f"implausible chunk length {length}")
        body = data[pos + 8 : pos + 8 + length]
        if len(body) != length or pos + 12 + length > len(data):
            bad(f"truncated {ctype_s} chunk")
        (crc_stored,) = struct.unpack(">I", data[pos + 8 + length : pos + 12 + length])
        if zlib.crc32(ctype + body) & 0xFFFFFFFF != crc_stored:
            bad(f"{ctype_s} chunk CRC mismatch")
        if ctype_s in seen and ctype_s in ("IHDR", "PLTE", "IEND"):
            bad(f"duplicate {ctype_s} chunk")
        seen.add(ctype_s)
        if ctype_s == "IHDR":
            if length != 13:
                bad("IHDR length != 13")
            w, h, depth, ct, comp, filt, interlace = struct.unpack(">IIBBBBB", body)
            if depth != 8:
                bad(f"bit depth {depth} != 8")
            if ct not in CHANNELS:
                bad(f"color type {ct} not allowed")
            if comp != 0 or filt != 0 or interlace != 0:
                bad(f"compression/filter/interlace must be 0/0/0, got {comp}/{filt}/{interlace}")
            ihdr = (w, h, ct)
        elif ctype_s == "IDAT":
            idat.extend(body)
        elif ctype_s == "PLTE":
            if length % 3 != 0:
                bad("PLTE length not a multiple of 3")
            if length // 3 > 256:
                bad("PLTE has more than 256 entries")
        pos += 12 + length
    if ihdr is None:
        bad("no IHDR chunk")
    if not idat:
        bad("no IDAT chunk")
    if "IEND" not in seen:
        bad("no IEND chunk")
    if pos != len(data):
        bad("trailing bytes after IEND")

    w, h, ct = ihdr
    channels = CHANNELS[ct]
    if ct == 3 and "PLTE" not in seen:
        bad("indexed image without PLTE")
    raw = zlib.decompress(bytes(idat))
    stride = w * channels
    if len(raw) != (stride + 1) * h:
        bad(f"decompressed IDAT size {len(raw)} != {(stride + 1) * h} for {w}x{h}")
    filters = {raw[y * (stride + 1)] for y in range(h)}
    if filters != {0}:
        bad(f"scanline filter types {sorted(filters)} != [0]")
    if w > 64 or h > 64:
        bad(f"fixture {w}x{h} exceeds the 64x64 fixture size cap")
    return w, h, ct


def render_decls(out_root: Path) -> Path:
    """Run render.js once with cwd=out_root; returns the produced output dir."""
    out_root.mkdir(parents=True, exist_ok=True)
    decl_paths = sorted(DECLS.glob("*.json"))
    if not decl_paths:
        fail(f"fixture_check: no declarations under {DECLS}")
        sys.exit(2)
    cmd = ["node", str(ROOT / "render.js")] + [str(p) for p in decl_paths]
    r = subprocess.run(cmd, cwd=out_root, capture_output=True, text=True)
    if r.returncode != 0:
        fail(f"fixture_check: render.js failed (exit {r.returncode}):\n{r.stdout}{r.stderr}")
        sys.exit(2)
    out_dir = out_root / "expected"
    if not out_dir.is_dir():
        fail(f"fixture_check: render.js produced no expected/ directory under {out_root}")
        sys.exit(2)
    return out_dir


def list_pngs(out_dir: Path) -> dict[str, bytes]:
    return {p.name: p.read_bytes() for p in sorted(out_dir.glob("*.png"))}


def main() -> int:
    ap = argparse.ArgumentParser(
        description="Double-run byte-identity fixture checker for tools/yoyopixel/render.js."
    )
    ap.add_argument(
        "--regen",
        action="store_true",
        help="rewrite fixtures/expected/*.png from the committed declarations",
    )
    args = ap.parse_args()

    version = node_version()
    if version != NODE_PIN:
        fail(f"fixture_check: node {version} != pinned {NODE_PIN} (docs/IMPLEMENT-Phase10.md correction 10)")
        return 2

    if args.regen:
        EXPECTED.mkdir(parents=True, exist_ok=True)
        render_decls(FIXTURES)  # cwd=FIXTURES: decl "file": "expected/<id>.png" lands in EXPECTED
        pngs = list_pngs(EXPECTED)
        print(f"regen: wrote {len(pngs)} fixture PNGs under {EXPECTED.relative_to(ROOT)}:")
        for fname, blob in pngs.items():
            print(f"  {fname} ({len(blob)} bytes)")
        return 0

    failures: list[str] = []
    with tempfile.TemporaryDirectory(prefix="yoyopixel-fixture-") as td:
        root = Path(td)
        run1 = list_pngs(render_decls(root / "run1"))
        run2 = list_pngs(render_decls(root / "run2"))
        committed = list_pngs(EXPECTED) if EXPECTED.is_dir() else {}

        for fname in sorted(set(run1) | set(run2) | set(committed)):
            b1, b2, bf = run1.get(fname), run2.get(fname), committed.get(fname)
            if b1 is None or b2 is None:
                failures.append(f"{fname}: missing from a run's output")
                continue
            try:
                w, h, ct = verify_png_structure(b1, fname)
            except ValueError as e:
                failures.append(str(e))
                continue
            if b1 != b2:
                failures.append(f"{fname}: run1 != run2 (non-deterministic)")
                continue
            if bf is None:
                failures.append(f"{fname}: no committed fixture under fixtures/expected/")
            elif b1 != bf:
                failures.append(f"{fname}: run output != committed fixture ({len(b1)} vs {len(bf)} bytes)")
            else:
                print(f"ok: {fname} ({w}x{h} {COLOR_TYPES[ct]}, {len(b1)} bytes; run1 == run2 == fixture)")

    if failures:
        for f in failures:
            fail(f"FAIL: {f}")
        fail(f"fixture_check: {len(failures)} failure(s)")
        return 1
    print(f"fixture_check: all outputs byte-identical (double run + committed fixtures), node {version}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
