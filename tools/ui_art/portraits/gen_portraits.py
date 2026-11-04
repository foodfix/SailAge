#!/usr/bin/env python3
"""gen_portraits.py — deterministic generator for the 25 portrait part sheets.

Phase-10 W3-D (`docs/IMPLEMENT-Phase10.md` A.7, `docs/80-UI-UX.md` §4.8).

Emits 25 render.js declarations (`pp_*.json`, string-map mode, RGBA,
72x96) beside this script, rasterized from the shared `anchors.json` plus
compact per-part shape specs below. Stdlib only; no randomness, no clock —
the only "random" is the fixed integer hash `h()`. Re-runs are
byte-identical (`--check` verifies against the committed files).

Palette discipline: every hex emitted is a `portrait` block hex
(`80-*` §4.8 table / `scripts/palette.gd` W2-A constants). Budget
48px+ = <= 25 per sheet; each sheet uses a small subset.

Part inventory (composer stack order, W4-D `portrait_composer.gd`):
  base -> face -> eyes -> beard -> hair -> cloth
  pp_base(1) pp_face_*(4) pp_eyes_*(4) pp_beard_*(4) pp_hair_*(4) pp_cloth_*(8)

Usage:
  python3 gen_portraits.py           # (re)write the 25 declarations in place
  python3 gen_portraits.py --check   # verify committed bytes, exit 1 on drift
"""
import argparse
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))

# ---- portrait block (docs/80-UI-UX.md §4.8) ---------------------------------
PAL = {
    "k": "#101010",  # PORTRAIT_INK  outline
    "h": "#f0d0b0",  # SKIN_HI
    "s": "#d9a878",  # SKIN
    "l": "#a87a52",  # SKIN_LO
    "b": "#1a1a1e",  # HAIR_BLACK
    "r": "#6b4a2a",  # HAIR_BROWN  (also the beard swap-source color, see README)
    "g": "#b9bcc0",  # HAIR_GREY
    "t": "#e8e6df",  # HAIR_STREAK (grey_streaked strands)
    "f": "#d9b98a",  # HAIR_BLEACHED
    "d": "#2e2014",  # EYE_DARK
    "y": "#8a929c",  # EYE_GREY
    "z": "#a87a28",  # EYE_HAZEL
    "p": "#9cc4dc",  # EYE_PALE_BLUE
    "A": "#d9a441",  # CLOTH_ACCENT  trader body; player trim; patrol/privateer sash (runtime re-tint target)
    "N": "#465468",  # CLOTH_LINE    coaster body; patrol/privateer neutral base
    "W": "#2f6f9e",  # CLOTH_SEA     courier body
    "G": "#4e9e4e",  # CLOTH_GOOD    hunter body
    "R": "#b3341f",  # CLOTH_BAD     pirate body
    "P": "#e8e6df",  # CLOTH_PLAYER  player body
}

# ---- deterministic hash (same structure as the vendored engine's H) ---------
def h(x, y):
    n = (x * 374761393 + y * 668265263 + 1013904223) & 0xffffffff
    n = (((n >> 13) ^ n) * 1274126177) & 0xffffffff
    return (((n >> 16) ^ n) & 0xffffffff) / 4294967296.0


# ---- tiny raster kit --------------------------------------------------------
class Sheet:
    def __init__(self, w, hgt):
        self.w, self.h = w, hgt
        self.c = {}          # (x, y) -> palette char

    def put(self, x, y, ch):
        if 0 <= x < self.w and 0 <= y < self.h:
            self.c[(x, y)] = ch

    def inside(self, x, y, cx, cy, rx, ry):
        dx = (x - cx) / rx
        dy = (y - cy) / ry
        return dx * dx + dy * dy <= 1.0

    def fill_region(self, region, ch, overwrite=True):
        for (x, y) in region:
            if overwrite or (x, y) not in self.c:
                self.put(x, y, ch)

    def outline(self, region, ch, crop_bottom=False):
        """1px ink on region cells with a 4-neighbor outside the region
        (out-of-canvas counts as inside when crop_bottom — the bust is
        cropped at y = h-1, so the bottom edge carries no outline)."""
        for (x, y) in region:
            for nx, ny in ((x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)):
                if ny >= self.h and crop_bottom:
                    continue
                if (nx, ny) not in region:
                    self.put(x, y, ch)
                    break

    def rows(self):
        return ["".join(self.c.get((x, y), ".") for x in range(self.w))
                for y in range(self.h)]


def region(fn, w, hgt):
    return {(x, y) for y in range(hgt) for x in range(w) if fn(x, y)}


# ---- anchors ----------------------------------------------------------------
with open(os.path.join(HERE, "anchors.json")) as _f:
    AN = json.load(_f)
CW = AN["canvas"]["w"]
CH = AN["canvas"]["h"]
HCX, HCY = AN["head"]["cx"], AN["head"]["cy"]
HRX, HRY = AN["head"]["rx"], AN["head"]["ry"]
HDR = AN["head"]["dilate"]
EYE = AN["eye_line"]
BROW_DY = AN["brow_dy"]
FRINGE = AN["hairline_dy"]
SLOPE = AN["hairline_slope"]
SB_DX = AN["sideburn_dx"]
BEARD_DY = AN["beard_band_dy"]
MUS = AN["mustache"]
NK = AN["neck"]
TOR = AN["torso"]
CO = AN["coat"]
SASH = AN["sash"]
BLO, BHI = AN["skin_ramp"]["band_lo"], AN["skin_ramp"]["band_hi"]

HEAD_IN = lambda x, y: (x - HCX) ** 2 / HRX ** 2 + (y - HCY) ** 2 / HRY ** 2 <= 1.0
HEAD_OUT = lambda x, y: (x - HCX) ** 2 / (HRX + HDR) ** 2 + (y - HCY) ** 2 / (HRY + HDR) ** 2 <= 1.0


def fringe_dy(dx, base=None):
    """hairline height (dy) at horizontal offset dx — drops toward the temples"""
    b = FRINGE if base is None else base
    return b + round(abs(dx) * SLOPE)


def torso_span(y):
    t = (y - TOR["y1"]) / (TOR["y2"] - TOR["y1"])
    return (round(TOR["x1_top"] - t * (TOR["x1_top"] - TOR["x1_bot"])),
            round(TOR["x2_top"] + t * (TOR["x2_bot"] - TOR["x2_top"])))


def coat_span(y):
    t = (y - CO["y1"]) / (CO["y2"] - CO["y1"])
    return (round(CO["x1_top"] - t * (CO["x1_top"] - CO["x1_bot"])),
            round(CO["x2_top"] + t * (CO["x2_bot"] - CO["x2_top"])))


def v_half(y):
    return max(0, round((CO["v_apex_y"] - y) * CO["v_half_w_top"]
                        / (CO["v_apex_y"] - CO["y1"])))


# ---- shared region unions ---------------------------------------------------
def base_region():
    """head ellipse + neck + torso trapezoid as ONE union (single outline)."""
    reg = {(x, y) for y in range(CH) for x in range(CW) if HEAD_IN(x, y)}
    reg |= {(x, y) for y in range(NK["y1"], NK["y2"] + 1)
            for x in range(NK["x1"], NK["x2"] + 1)}
    for y in range(TOR["y1"], TOR["y2"] + 1):
        x1, x2 = torso_span(y)
        reg |= {(x, y) for x in range(x1, x2 + 1)}
    return reg


def skin_ramp_char(x, y, cx, cy, rx, ry):
    q = (x - cx) / rx + (y - cy) / ry
    hv = h(x, y)
    if q < -BHI:
        return "h"
    if q < -BLO:
        return "h" if hv < 0.5 else "s"
    if q <= BLO:
        return "s"
    if q <= BHI:
        return "l" if hv < 0.5 else "s"
    return "l"


def hair_region(base_fringe=None):
    """dilated-ellipse cap above the hairline + sideburn strips, one region."""
    reg = {(x, y) for y in range(CH) for x in range(CW)
           if HEAD_OUT(x, y) and (y - HCY) <= fringe_dy(x - HCX, base_fringe)}
    reg |= {(x, y) for y in range(CH) for x in range(CW)
            if abs(x - HCX) >= SB_DX and HEAD_OUT(x, y)
            and -8 <= (y - HCY) <= 0}
    return reg


# ---- part builders ----------------------------------------------------------
def build_base():
    sh = Sheet(CW, CH)
    reg = base_region()
    for (x, y) in reg:
        if HEAD_IN(x, y):
            ch = skin_ramp_char(x, y, HCX, HCY, HRX, HRY)
        elif NK["x1"] <= x <= NK["x2"] and NK["y1"] <= y <= NK["y2"]:
            ch = "s"
            if 51 <= y <= 53:
                ch = "l"          # under-chin shadow
            elif x == NK["x2"] and y >= 54:
                ch = "l"          # east neck column (light from NW)
        else:
            ch = skin_ramp_char(x, y, 36, 79, 14, 16)
        sh.put(x, y, ch)
    sh.outline(reg, "k", crop_bottom=True)
    return sh


def face_common(sh):
    """features shared by all four face sheets (brows + nose hint) so any
    face over the base reads as a face"""
    for x in range(HCX - EYE["dx"] - 1, HCX - EYE["dx"] + EYE["half_w"] + 2):
        sh.put(x, HCY + BROW_DY, "l")
        sh.put(x + 2 * EYE["dx"], HCY + BROW_DY, "l")
    sh.put(HCX, HCY + 3, "l")
    sh.put(HCX, HCY + 4, "l")


def build_face(kind):
    sh = Sheet(CW, CH)
    face_common(sh)
    li = lambda x, y: sh.put(x, y, "l")
    hi = lambda x, y: sh.put(x, y, "h")
    if kind == "lean":
        for y in range(37, 42):
            li(26, y); li(27, y); li(28, y)
            li(44, y); li(45, y); li(46, y)
        li(31, 41); li(30, 42); li(30, 43)
        li(41, 41); li(42, 42); li(42, 43)
    elif kind == "round":
        for (x, y) in region(lambda x, y: (x - 29) ** 2 + (y - 39) ** 2 <= 4, CW, CH):
            hi(x, y)
        for (x, y) in region(lambda x, y: (x - 43) ** 2 + (y - 39) ** 2 <= 4, CW, CH):
            hi(x, y)
        hi(35, 45); hi(36, 45); hi(37, 45)
    elif kind == "scarred":
        # scar: SKIN_LO diagonal across the left cheek + cross ticks
        pts = [(28, 30), (29, 31), (29, 32), (30, 33), (31, 34)]
        for (x, y) in pts:
            li(x, y)
        li(27, 32); li(30, 31)
        for y in range(38, 41):
            li(26, y); li(27, y)
            li(46, y); li(45, y)
    elif kind == "weathered":
        for x in range(31, 35):
            li(x, 30)          # forehead dashes
            li(x + 7, 30)
        li(36, 31)             # glabella
        li(31, 38); li(32, 38)  # under-eye lines
        li(40, 38); li(41, 38)
        li(25, 35); li(26, 36)  # crow's feet
        li(47, 35); li(46, 36)
        li(31, 41); li(30, 42)  # nasolabial
        li(41, 41); li(42, 42)
    else:
        raise ValueError(kind)
    return sh


def build_eyes(color):
    sh = Sheet(CW, CH)
    y0 = HCY + EYE["top_dy"]
    for side in (-1, +1):
        cx = HCX + side * EYE["dx"]
        for dx in range(-EYE["half_w"], EYE["half_w"] + 1):
            for dy in range(EYE["rows"]):
                sh.put(cx + dx, y0 + dy, color)
        sh.put(cx, y0 + EYE["rows"] - 1, "k")  # pupil
    return sh


def beard_region_cells():
    """lower-band interior cells (1px inside the ink ring) + side connectors"""
    cells = set()
    for y in range(CH):
        for x in range(CW):
            if not HEAD_IN(x, y):
                continue
            # interior: every 4-neighbor still inside the head ellipse
            if not all(HEAD_IN(x + dx, y + dy)
                       for dx, dy in ((-1, 0), (1, 0), (0, -1), (0, 1))):
                continue
            dy_ = y - HCY
            dx_ = abs(x - HCX)
            if dy_ >= BEARD_DY:
                cells.add((x, y))
            elif dy_ >= 4 and dx_ >= 9:
                cells.add((x, y))      # sideburn connectors
    return cells


def build_beard(kind):
    sh = Sheet(CW, CH)
    if kind == "clean":
        return sh                   # fully transparent layer (A.7 keeps the file)
    mus = {(x, y) for y in range(HCY + MUS["top_dy"], HCY + MUS["bot_dy"] + 1)
           for x in range(HCX - MUS["half_w"], HCX + MUS["half_w"] + 1)
           if HEAD_IN(x, y)}
    if kind == "full":
        cells = beard_region_cells() | mus
        sh.fill_region(cells, "r")
    elif kind == "forked":
        cells = set(mus)
        for (x, y) in beard_region_cells():
            dy_ = y - HCY
            if dy_ >= 12:
                cells.add((x, y))                      # jaw rim
            elif dy_ >= 8 and abs(x - HCX) <= 2:
                cells.add((x, y))                      # chin column
        sh.fill_region(cells, "r")
        # pointed tail below the chin (over the neck skin)
        sh.put(35, 55, "r"); sh.put(36, 55, "r"); sh.put(37, 55, "r")
        sh.put(36, 56, "r")
    elif kind == "stubble":
        for (x, y) in beard_region_cells() | mus:
            dy_ = y - HCY
            # keep speckles 1px off the ink ring: interior-only cells
            if not all(HEAD_IN(x + dx, y + dy)
                       for dx, dy in ((-1, 0), (1, 0), (0, -1), (0, 1),
                                      (-1, -1), (1, 1), (1, -1), (-1, 1))):
                continue
            if dy_ >= 10 and h(x, y) < 0.12:
                sh.put(x, y, "r")
            elif 6 <= dy_ < 9 and h(x, y) < 0.15:   # upper-lip / cheek speckle
                sh.put(x, y, "r")
    else:
        raise ValueError(kind)
    return sh


def build_hair(color, base_fringe=None, center_peak=False, streaks=False):
    sh = Sheet(CW, CH)
    b = base_fringe
    reg = set()
    for y in range(CH):
        for x in range(CW):
            if not HEAD_OUT(x, y):
                continue
            dx = x - HCX
            f = fringe_dy(dx, b)
            if center_peak and abs(dx) <= 1:
                f += 1
            if (y - HCY) <= f:
                reg.add((x, y))
            elif abs(dx) >= SB_DX and -8 <= (y - HCY) <= 0:
                reg.add((x, y))
    interior = {(x, y) for (x, y) in reg
                if all((nx, ny) in reg
                       for nx, ny in ((x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)))}
    sh.fill_region(reg, color)
    sh.outline(reg, "k")
    if streaks:
        for sx in (HCX - 6, HCX - 3, HCX + 3, HCX + 6):
            for y in range(HCY + fringe_dy(sx - HCX, b), HCY - 2):
                if (sx, y) in interior:
                    sh.put(sx, y, "t")
    return sh


def cloth_region():
    """coat trapezoid minus the chest-V opening (base skin shows there)."""
    reg = set()
    for y in range(CO["y1"], CO["y2"] + 1):
        x1, x2 = coat_span(y)
        v = v_half(y)
        for x in range(x1, x2 + 1):
            if v > 0 and abs(x - HCX) <= v:
                continue
            reg.add((x, y))
    return reg


def build_cloth(body, trim=None, sash=False, body_is_light=False):
    sh = Sheet(CW, CH)
    reg = cloth_region()
    sh.fill_region(reg, body)
    if sash:
        for y in range(SASH["origin_y"], CO["y2"] + 1):
            for x in range(CW):
                if (x, y) in reg and abs((y - SASH["origin_y"]) - (x - SASH["origin_x"])) <= SASH["band_half_w"]:
                    sh.put(x, y, "A")
    sh.outline(reg, "k", crop_bottom=True)
    if trim:  # collar trim re-inks the concave V-edge seam (coat cells
        # 4-adjacent to the chest-V opening)
        vset = {(x, y) for y in range(CO["y1"], CO["v_apex_y"] + 1)
                for x in range(CW)
                if v_half(y) > 0 and abs(x - HCX) <= v_half(y)}
        for (x, y) in reg:
            for nx, ny in ((x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)):
                if (nx, ny) in vset:
                    sh.put(x, y, trim)
                    break
    # NW rim dither on dark coats / SE rim on the light player coat
    for (x, y) in reg:
        x1, x2 = coat_span(y)
        if not body_is_light:
            if (y <= CO["y1"] + 2 or x <= x1 + 1) and h(x, y) < 0.3:
                sh.put(x, y, "h")
        else:
            if (y >= CO["y2"] - 2 or x >= x2 - 1) and h(x, y) < 0.3:
                sh.put(x, y, "l")
    return sh


# ---- declarations -----------------------------------------------------------
def emit(name, sheet, note):
    rows = sheet.rows()
    used = sorted(set("".join(rows)) - {"."})
    pal = {".": "transparent"}
    for ch in used:
        pal[ch] = PAL[ch]
    decl = {
        "id": name,
        "file": "assets/ui/portraits/%s.png" % name,
        "mode": "string-map",
        "png": "rgba",
        "width": CW,
        "height": CH,
        "comment": note,
        "palette": pal,
        "rows": rows,
    }
    return json.dumps(decl, indent=1, sort_keys=True) + "\n"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true",
                    help="compare regenerated bytes against the committed files")
    args = ap.parse_args()

    parts = []
    parts.append(("pp_base", build_base(),
                  "shared bust under-layer: head/neck/shoulders silhouette, "
                  "3-step skin ramp (NW light), PORTRAIT_INK outline. "
                  "Composer stack: base -> face -> eyes -> beard -> hair -> cloth."))

    faces = {
        "lean": "hollowed cheeks + nasolabial lines (SKIN_LO)",
        "round": "full cheeks (SKIN_HI) + soft chin",
        "scarred": "SKIN_LO scar line + ticks across the left cheek",
        "weathered": "SKIN_LO wrinkles: forehead, under-eye, crow's feet, nasolabial",
    }
    for kind, note in faces.items():
        parts.append(("pp_face_%s" % kind, build_face(kind),
                      "face overlay on the shared head position: brows + nose hint "
                      "common to all faces; " + note + "."))

    for eid, ch in (("dark", "d"), ("grey", "y"), ("hazel", "z"), ("pale_blue", "p")):
        parts.append(("pp_eyes_%s" % eid, build_eyes(ch),
                      "3x2 eye clusters at the anchored coordinates (dx +-%d from "
                      "head center), bottom-center pixel is the ink pupil. Same "
                      "cells for every eye id." % EYE["dx"]))

    beards = {
        "clean": "fully transparent layer — the composer may skip it; shipped "
                 "per A.7 so the part id always resolves",
        "full": "full beard: lower band + sideburn connectors + mustache",
        "forked": "pointed goatee: jaw rim + chin column + mustache + tail spike",
        "stubble": "1px speckle band (hash < 0.3), <= 30% dither",
    }
    for kind, note in beards.items():
        parts.append(("pp_beard_%s" % kind, build_beard(kind),
                      "beard anchored to the shared jaw line, rendered in "
                      "HAIR_BROWN as the palette-swap source: the runtime "
                      "composer re-maps beard pixels to the captain's hair hex "
                      "(same swap mechanism as the patrol/privateer sash). " + note + "."))

    hairs = {
        "black": ("b", None, False, False),
        "brown": ("r", None, True, False),
        "grey_streaked": ("g", None, False, True),
        "sun_bleached": ("f", FRINGE - 1, False, False),
    }
    for hid, (ch, bf, peak, streaks) in hairs.items():
        note = "crown cap + sideburns on the shared head silhouette"
        if hid == "brown":
            note += "; 1px center widow's-peak variant"
        elif hid == "grey_streaked":
            note += "; HAIR_GREY base with 4 HAIR_STREAK strands"
        elif hid == "sun_bleached":
            note += "; receded hairline variant"
        parts.append(("pp_hair_%s" % hid, build_hair(ch, bf, peak, streaks),
                      note + "."))

    cloths = {
        "trader": ("A", None, False, False,
                   "trader coat in CLOTH_ACCENT (80-* 4.8 cloth rule)"),
        "coaster": ("N", None, False, False,
                    "coaster coat in CLOTH_LINE"),
        "courier": ("W", None, False, False,
                    "courier coat in CLOTH_SEA"),
        "patrol": ("N", None, True, False,
                   "patrol: neutral CLOTH_LINE base + CLOTH_ACCENT sash — the "
                   "RUNTIME composer (W4-D) may re-tint the sash to the owner "
                   "nation's CLOTH_{nation} hex via palette swap; the sheet "
                   "itself stays palette-block-clean"),
        "privateer": ("N", None, True, False,
                      "privateer: neutral CLOTH_LINE base + CLOTH_ACCENT sash — "
                      "same runtime re-tint adjudication as pp_cloth_patrol"),
        "pirate": ("R", None, False, False,
                   "pirate coat in CLOTH_BAD"),
        "hunter": ("G", None, False, False,
                   "hunter coat in CLOTH_GOOD"),
        "player": ("P", "A", False, True,
                   "player coat in CLOTH_PLAYER with CLOTH_ACCENT collar trim "
                   "(80-* 4.8); SE shadow dither (light cloth, NW light)"),
    }
    for role, (body, trim, sash, light, note) in cloths.items():
        parts.append(("pp_cloth_%s" % role, build_cloth(body, trim, sash, light),
                      "shoulders/coat layer; " + note + "."))

    ok = True
    for name, sheet, note in parts:
        data = emit(name, sheet, note)
        path = os.path.join(HERE, name + ".json")
        if args.check:
            with open(path) as f:
                if f.read() != data:
                    print("DRIFT %s" % name)
                    ok = False
        else:
            with open(path, "w") as f:
                f.write(data)
            print("wrote %s" % name)
    if args.check:
        print("%d sheets checked: %s" % (len(parts), "byte-identical" if ok else "DRIFT"))
        return 0 if ok else 1
    print("%d declarations written" % len(parts))
    return 0


if __name__ == "__main__":
    sys.exit(main())
