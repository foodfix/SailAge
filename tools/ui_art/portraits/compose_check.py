#!/usr/bin/env python3
"""compose_check.py — W3-D gate checker for the portrait part sheets + FX frames.

Runs the vendored engine (`tools/yoyopixel/render.js`, node pinned v24.16.0)
over the committed declarations, then asserts — stdlib only, no Godot:

  FX (11 frames, tools/ui_art/fx/*.json)
    - every declaration renders, at its declared size, RGBA
    - every opaque pixel hex is in the `fx` palette block (80-* 4.8)

  Portraits (25 part sheets, tools/ui_art/portraits/pp_*.json)
    - every sheet renders 72x96 RGBA
    - every opaque pixel hex is in the `portrait` palette block
    - ANCHOR ALIGNMENT (the composer contract):
        * the four pp_eyes_* sheets occupy the exact same cell set
        * pp_beard_clean is fully transparent; beard pixels stay in the
          lower head region (+ the forked tail box below the chin)
        * face pixels stay strictly inside the head ellipse
        * hair pixels stay in the crown/sideburn box, never below eye level
        * cloth pixels stay at/below the shoulder line and cover probe cells
        * role cloth bodies/sashes carry the pinned hexes
    - compose sample stacks (base -> face -> eyes -> beard -> hair -> cloth)
      for fixed legend appearances and prove each layer lands

Prints an ASCII downsample of one composed bust for the log. Renders and
composites go to a temp directory only — nothing is written under assets/.

Usage: python3 tools/ui_art/portraits/compose_check.py
Exit 0 = all green.
"""
import json
import os
import struct
import subprocess
import sys
import tempfile
import zlib

HERE = os.path.dirname(os.path.abspath(__file__))
TOOLS = os.path.abspath(os.path.join(HERE, "..", ".."))
RENDER = os.path.join(TOOLS, "yoyopixel", "render.js")

# 80-* 4.8 palette blocks
FX_BLOCK = {
    "#26262c", "#8a929c", "#c6ccd4", "#555c66", "#dff0f4",
    "#9fc4d4", "#7a2d16", "#ff8c2a", "#ffd23e",
}
PORTRAIT_BLOCK = {
    "#101010", "#f0d0b0", "#d9a878", "#a87a52",
    "#1a1a1e", "#6b4a2a", "#b9bcc0", "#e8e6df", "#d9b98a",
    "#2e2014", "#8a929c", "#a87a28", "#9cc4dc",
    "#d9a441", "#465468", "#2f6f9e", "#4e9e4e", "#b3341f",
    "#1a8c4e", "#b3191f", "#274b8f", "#d97b1e", "#6a3d9a", "#c9a227",
}
CLOTH_BODY = {
    "trader": "#d9a441", "coaster": "#465468", "courier": "#2f6f9e",
    "patrol": "#465468", "privateer": "#465468", "pirate": "#b3341f",
    "hunter": "#4e9e4e", "player": "#e8e6df",
}
HEAD = {"cx": 36, "cy": 35, "rx": 13, "ry": 19}
EYE_CELLS = {(x, y) for cx in (32, 40) for x in range(cx - 1, cx + 2)
             for y in (35, 36)}
SHOULDER_Y = 64
CLOTH_PROBES = [(24, 68), (48, 68), (20, 90), (52, 90)]

# fixed legend appearances (subset of data/captains.json legend set;
# covers all 4 faces / beards / hairs / eye colors)
SAMPLES = [
    ("cap_leg_patrol_01", ["pp_base", "pp_face_weathered", "pp_eyes_grey",
                           "pp_beard_stubble", "pp_hair_brown", "pp_cloth_patrol"]),
    ("pirate_redbeard_khair", ["pp_base", "pp_face_scarred", "pp_eyes_dark",
                               "pp_beard_full", "pp_hair_grey_streaked", "pp_cloth_pirate"]),
    ("cap_leg_trader_01", ["pp_base", "pp_face_round", "pp_eyes_hazel",
                           "pp_beard_clean", "pp_hair_brown", "pp_cloth_trader"]),
    ("player", ["pp_base", "pp_face_lean", "pp_eyes_pale_blue",
                "pp_beard_clean", "pp_hair_sun_bleached", "pp_cloth_player"]),
]
STACK_ORDER = ("base -> face -> eyes -> beard -> hair -> cloth")

FAILS = []


def check(cond, msg):
    if cond:
        print("  ok   %s" % msg)
    else:
        print("  FAIL %s" % msg)
        FAILS.append(msg)


def run_node(decl_paths, out_dir):
    r = subprocess.run(["node", RENDER] + decl_paths, cwd=out_dir,
                       capture_output=True, text=True)
    return r


def read_png(path):
    with open(path, "rb") as f:
        b = f.read()
    assert b[:8] == b"\x89PNG\r\n\x1a\n", path
    pos, w, h, idat, ctype = 8, None, None, b"", None
    while pos < len(b):
        ln = struct.unpack(">I", b[pos:pos + 4])[0]
        typ = b[pos + 4:pos + 8]
        data = b[pos + 8:pos + 8 + ln]
        if typ == b"IHDR":
            w, h, depth, ctype = struct.unpack(">IIBB", data[:10])
            assert depth == 8
        elif typ == b"IDAT":
            idat += data
        pos += 12 + ln
    assert ctype == 6, "expected RGBA, got color type %r (%s)" % (ctype, path)
    raw = zlib.decompress(idat)
    stride = w * 4
    px = []
    for y in range(h):
        off = y * (stride + 1)
        assert raw[off] == 0, "filter != 0 (%s)" % path
        row = raw[off + 1:off + 1 + stride]
        px.append([(row[x * 4], row[x * 4 + 1], row[x * 4 + 2], row[x * 4 + 3])
                   for x in range(w)])
    return w, h, px


def opaque_cells(px):
    return {(x, y): "#%02x%02x%02x" % px[y][x][:3]
            for y in range(len(px)) for x in range(len(px[0]))
            if px[y][x][3] > 0}


def render_dir(tmp, decl_dir, pattern):
    decls = sorted(os.path.join(decl_dir, f) for f in os.listdir(decl_dir)
                   if f.endswith(".json") and (pattern is None or pattern(f)))
    r = run_node(decls, tmp)
    if r.returncode != 0:
        print(r.stdout)
        print(r.stderr)
        raise SystemExit("render.js failed (exit %d)" % r.returncode)
    return decls


def main():
    tmp = tempfile.mkdtemp(prefix="w3d_compose_check_")
    print("scratch: %s" % tmp)

    # ---- FX -------------------------------------------------------------
    print("== FX frames (tools/ui_art/fx)")
    fx_dir = os.path.join(TOOLS, "ui_art", "fx")
    decls = render_dir(tmp, fx_dir, None)
    check(len(decls) == 11, "11 fx declarations present (found %d)" % len(decls))
    fx_out = os.path.join(tmp, "assets", "ui", "fx")
    for f in sorted(os.listdir(fx_dir)):
        if not f.endswith(".json"):
            continue
        decl = json.load(open(os.path.join(fx_dir, f)))
        name = decl["id"]
        w, h, px = read_png(os.path.join(fx_out, name + ".png"))
        check((w, h) == (decl["width"], decl["height"]) == (
            (16, 16) if name.startswith(("fx_cannonball", "fx_smoke"))
            else (32, 32)), "%s renders %dx%d" % (name, w, h))
        bad = sorted({c for c in opaque_cells(px).values()} - FX_BLOCK)
        check(not bad, "%s hexes in fx block %s" % (name, bad or ""))

    # ---- Portraits --------------------------------------------------------
    print("== Portrait part sheets (tools/ui_art/portraits)")
    sheets = {}
    out = os.path.join(tmp, "assets", "ui", "portraits")
    pp_files = sorted(f for f in os.listdir(HERE)
                      if f.startswith("pp_") and f.endswith(".json"))
    check(len(pp_files) == 25, "25 part-sheet declarations present (found %d)" % len(pp_files))
    r = run_node([os.path.join(HERE, f) for f in pp_files], tmp)
    if r.returncode != 0:
        print(r.stderr)
        raise SystemExit("render.js failed")
    for f in pp_files:
        name = f[:-5]
        w, h, px = read_png(os.path.join(out, name + ".png"))
        check((w, h) == (72, 96), "%s renders 72x96" % name)
        cells = opaque_cells(px)
        sheets[name] = cells
        bad = sorted(set(cells.values()) - PORTRAIT_BLOCK)
        check(not bad, "%s hexes in portrait block %s" % (name, bad or ""))

    def cells_of(prefix):
        return {n: c for n, c in sheets.items() if n.startswith(prefix)}

    # eyes: identical cell sets
    eyes = cells_of("pp_eyes_")
    sets = {n: frozenset(c) for n, c in eyes.items()}
    check(len(sets) == 4 and len(set(sets.values())) == 1,
          "4 eye sheets share one cell set")
    check(next(iter(sets.values())) == frozenset(EYE_CELLS),
          "eye cells match the anchored clusters")

    # beards
    check(not sheets["pp_beard_clean"], "pp_beard_clean fully transparent")
    beard_ok = True
    for n, c in cells_of("pp_beard_").items():
        if n == "pp_beard_clean":
            continue
        for (x, y) in c:
            in_head = ((x - HEAD["cx"]) / HEAD["rx"]) ** 2 + \
                      ((y - HEAD["cy"]) / HEAD["ry"]) ** 2 <= 1.0
            tail = (35 <= x <= 37 and y == 55) or (x == 36 and y == 56)
            if not (in_head or tail) or y < 38:
                beard_ok = False
    check(beard_ok, "beard pixels stay in the lower head (+ forked tail box)")

    # faces inside the head ellipse
    face_ok = True
    for n, c in cells_of("pp_face_").items():
        for (x, y) in c:
            if ((x - HEAD["cx"]) / HEAD["rx"]) ** 2 + \
               ((y - HEAD["cy"]) / HEAD["ry"]) ** 2 > 1.0:
                face_ok = False
    check(face_ok, "face pixels stay inside the head ellipse")

    # hair: crown box, never below eye level
    hair_ok = True
    for n, c in cells_of("pp_hair_").items():
        if not c:
            hair_ok = False
        for (x, y) in c:
            if not (20 <= x <= 52 and 14 <= y <= 38):
                hair_ok = False
    check(hair_ok, "hair pixels stay in the crown/sideburn box (y <= 38)")

    # cloth: at/below shoulder line, probes covered, pinned hexes present
    for n, c in cells_of("pp_cloth_").items():
        role = n[len("pp_cloth_"):]
        check(all(y >= SHOULDER_Y - 2 for (_, y) in c),
              "%s stays at/below the shoulder line" % n)
        check(all(p in c for p in CLOTH_PROBES), "%s covers probe cells" % n)
        check(CLOTH_BODY[role] in set(c.values()), "%s carries its body hex" % n)
        if role in ("patrol", "privateer"):
            check("#d9a441" in set(c.values()), "%s carries the sash hex" % n)
        if role == "player":
            check("#d9a441" in set(c.values()), "player carries the ACCENT trim")

    # ---- compose -----------------------------------------------------------
    print("== compose (stack order: %s)" % STACK_ORDER)
    ASC = {"#101010": "k", "#f0d0b0": "h", "#d9a878": "s", "#a87a52": "l",
           "#1a1a1e": "B", "#6b4a2a": "r", "#b9bcc0": "g", "#e8e6df": "W",
           "#d9b98a": "f", "#2e2014": "d", "#8a929c": "y", "#a87a28": "z",
           "#9cc4dc": "p", "#d9a441": "A", "#465468": "N", "#2f6f9e": "S",
           "#4e9e4e": "G", "#b3341f": "R", "#1a8c4e": "1", "#b3191f": "2",
           "#274b8f": "3", "#d97b1e": "4", "#6a3d9a": "5", "#c9a227": "6"}
    first_ascii = None
    for (cap, stack) in SAMPLES:
        canvas = [[None] * 72 for _ in range(96)]
        for name in stack:                     # later layers win (W4-D order)
            for (x, y), hexv in sheets[name].items():
                canvas[y][x] = hexv
        check(canvas[35][36] is not None and canvas[60][36] is not None
              and canvas[80][20] is not None,
              "%s: head/neck/torso cells land after compose" % cap)
        check(canvas[35][32] in ("#2e2014", "#8a929c", "#a87a28", "#9cc4dc"),
              "%s: eye pixel survives under hair/cloth" % cap)
        check(canvas[72][20] == CLOTH_BODY[stack[-1][len("pp_cloth_"):]],
              "%s: cloth body off-sash at the shoulder" % cap)
        if stack[-1] in ("pp_cloth_patrol", "pp_cloth_privateer"):
            check(canvas[70][24] == "#d9a441",
                  "%s: sash hex at the sash origin" % cap)
        if first_ascii is None:
            first_ascii = canvas
        # write the composed RGBA PNG for human eyeballing (scratch only)
        raw = b"".join(
            b"\x00" + b"".join(
                bytes((int(hx[1:3], 16), int(hx[3:5], 16), int(hx[5:7], 16), 255))
                if hx else bytes(4)
                for hx in row)
            for row in canvas)
        chunk = lambda t, d: (struct.pack(">I", len(d)) + t + d +
                              struct.pack(">I", zlib.crc32(t + d) & 0xffffffff))
        with open(os.path.join(tmp, "bust_%s.png" % cap), "wb") as f:
            f.write(b"\x89PNG\r\n\x1a\n"
                    + chunk(b"IHDR", struct.pack(">IIBBBBB", 72, 96, 8, 6, 0, 0, 0))
                    + chunk(b"IDAT", zlib.compress(raw, 9)) + chunk(b"IEND", b""))
    print("  composed busts -> %s/bust_*.png" % tmp)
    print("  ASCII bust_cap_leg_patrol_01 (72x96, legend hex letters):")
    for y in range(0, 96, 2):
        line = "".join(ASC.get(first_ascii[y][x], ".") if first_ascii[y][x] else "."
                       for x in range(72))
        print("  |" + line + "|")

    print()
    if FAILS:
        print("compose_check: %d FAILURE(S)" % len(FAILS))
        return 1
    print("compose_check: ALL GREEN")
    return 0


if __name__ == "__main__":
    sys.exit(main())
