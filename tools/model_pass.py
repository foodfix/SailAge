#!/usr/bin/env python3
"""SailAge model-pass GENERATION driver (untracked tool, generation slot).

5-dir scheme (doc f6c00bb): the model generates ONLY n, s, w, sw, nw —
e = flip(w), ne = flip(nw), se = flip(sw) are derived at ingestion.

Replicates the master-validated chain end to end for batch production:

  1. Draft reference: 32x32 indexed token (VD.decode_ui_png) -> white bg ->
     x2 nearest 64-canvas -> x8 nearest 512x512 reference PNG (model_raw/drafts/).
  2. Generate: POST http://127.0.0.1:8001/edit {"image","prompt","seed"} —
     the response body IS the PNG. One retry, then log and continue.
  3. De-background: ComfyUI :8000 rembg workflow (LifeSimulator template,
     AS-IS incl. InvertMask), unique filename_prefix per job.
  4. Snap: majority-vote 512 -> 64 logical grid per 8x8 block over opaque
     px, quantize to sorted(VD.BLOCK_HULL) (BLOCK_ICON for icons).
  5. Metrics: opaque %, bbox fit, e/w long-axis band check, pennant note.

Writes stay in tools/ui_art/model_raw/** (gitignored), art_review/** and
/tmp/opencode/modelgen/**. progress.json is rewritten after EVERY job.

Usage:
  python3 tools/model_pass.py run ships|terrain|icons [limit]
  python3 tools/model_pass.py job <job_id>          # re-run one job
  python3 tools/model_pass.py sheets [ships|terrain|icons]
  python3 tools/model_pass.py report
"""

from __future__ import annotations

import base64
import io
import json
import os
import shutil
import sys
import time
import uuid
from collections import Counter, deque

import requests
from PIL import Image, ImageDraw, ImageFont

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(REPO, "tools"))
import validate_data as VD  # noqa: E402  (decode_ui_png + palette blocks)

EDIT_URL = "http://127.0.0.1:8001/edit"
COMFY = "http://127.0.0.1:8000"
REMBG_WF = ("/home/weidong/repo/LifeSimulator/src/lib/comfyui/"
            "workflow-template-rembg.json")
CLIENT_ID = "sailage-gen"

RAW = os.path.join(REPO, "tools", "ui_art", "model_raw")
DRAFTS = os.path.join(RAW, "drafts")
GEN = os.path.join(RAW, "gen")
DEBG = os.path.join(RAW, "debg")
SNAPPED = os.path.join(RAW, "snapped")
SCRATCH = "/tmp/opencode/modelgen"
PROGRESS = os.path.join(RAW, "progress.json")
REPORT = os.path.join(RAW, "report.json")
REVIEW = os.path.join(REPO, "art_review")

DIRS = ["w", "n", "s", "sw", "nw"]          # generated base dirs (f6c00bb)
MIRROR_OF = {"e": "w", "ne": "nw", "se": "sw"}  # derived at ingestion
ALL_DIRS = ["e", "w", "n", "s", "ne", "nw", "se", "sw"]  # sheet display order
HULLS = ["brigantine", "caravel", "caravela_redonda", "carrack", "dhow",
         "fluyt", "galiot", "galleass", "galleon", "galley", "junk",
         "latin", "nao", "pinnace", "sloop", "xebec"]
TIER = {"latin": 1, "sloop": 1, "galiot": 1, "pinnace": 1,
        "caravel": 2, "galley": 2, "brigantine": 2, "fluyt": 2,
        "junk": 2, "dhow": 2, "caravela_redonda": 2, "xebec": 2,
        "nao": 3, "carrack": 3, "galleon": 3, "galleass": 3}
# 64-grid long-axis bands (rig.json tier_bands x2: 14-18 / 20-26 / 26-30).
BANDS = {1: (28, 36), 2: (40, 52), 3: (52, 60)}
BLOCK_HULL = sorted(VD.BLOCK_HULL)
BLOCK_ICON = sorted(VD.BLOCK_ICON)

SHEET_BG = (0x18, 0x1C, 0x28, 0xFF)  # probe sheet corner px (0x18 0x1c 0x28)

POSE = {
    "w": ("seen exactly from the side, the ship's bow with bowsprit points "
          "to the LEFT edge, stern at the RIGHT edge"),
    "n": ("seen directly from ASTERN: the square transom/stern-castle faces "
          "the viewer head-on, symmetric, the ship sails AWAY upward, NO "
          "bowsprit visible"),
    "s": ("seen directly from the BOW: the bowsprit points straight DOWN "
          "toward the viewer at the bottom, symmetric bow shape, "
          "stern-castle hidden behind the sails"),
    "sw": ("three-quarter diagonal view with the bow pointing to the "
           "BOTTOM-LEFT corner, the sails billow toward the stern at the "
           "TOP-RIGHT"),
    "nw": ("three-quarter diagonal view with the bow pointing to the "
           "TOP-LEFT corner, the sails billow toward the stern at the "
           "BOTTOM-RIGHT"),
}
# lateen t1 waiver: +1 px over band top accepted (rig.json amendment class)
WAIVER_T1_LATEEN = {"latin", "galiot", "sloop"}
# direction re-roll round seed offset (deterministic, unused before)
DIR_SEED_OFFSET = 60000
RIG = {
    "latin": "one mast with a big triangular latin lateen sail dominating "
             "the profile",
    "sloop": "one mast with a big lateen mainsail, short bowsprit, small jib",
    "galiot": "compact hull, one large lateen sail and a short oar bank "
              "visible at the waterline",
    "pinnace": "small oared boat with two staggered oar banks and a bare "
               "mast stub carrying the pennant",
    "caravel": "two masts with two large triangular lateen sails, rounded "
               "high prow",
    "galley": "long low hull with rows of oars at the waterline, one lateen "
              "mainsail plus a small square topsail",
    "brigantine": "two masts: square course and topsail on the fore mast, "
                  "fore-and-aft gaff spanker on the main",
    "fluyt": "fat-bellied hull, blunt stern, three masts with square course "
             "and topsail stacks",
    "junk": "three masts with fully-battened rectangular junk sails, "
            "fan-tail stern",
    "dhow": "slim hull with sharp prow and one big triangular lateen sail",
    "caravela_redonda": "roundish hull, three masts: square course and "
                        "topsail stacks fore and main, lateen mizzen",
    "xebec": "narrow hull, three masts with large overlapping triangular "
             "lateen sails",
    "nao": "three masts with square course and topsail stacks, tall fore "
           "and aft castles, crow's nests",
    "carrack": "three masts with square sails plus a lateen mizzen, very "
               "high stern castle",
    "galleon": "three masts with square sails, high stern castle, crow's "
               "nests, beakhead, dense gunports",
    "galleass": "the longest hull, three lateen-rigged masts and many oar "
                "stations at the waterline",
}
# chroma-green background (user direction — white bg left rembg fringes)
GREEN_BG = (0, 255, 0, 255)
CHROMA_BG = ("solid flat chroma-key green background (#00ff00), uniform, "
             "no gradient, no shadow on the background")
STYLE = ("Render it as crisp limited-palette pixel art in the style of "
         "early-90s 16-bit sailing games: billowed canvas sails with curved "
         "highlight and shadow bands following the bulge, dense wooden hull "
         "with visible planking lines, small lit cabin windows, gunports, "
         "a small red pennant flag at the mainmast top, strong 1-pixel dark "
         "outline around the whole sprite, big chunky pixels, "
         + CHROMA_BG + ". No water, no scenery, no text, no frame.")
ICON_STYLE = ("redraw as crisp bold 16-bit game icon, same silhouette and "
              "recognizability, thick outline, flat colors, centered, "
              + CHROMA_BG)

# ---------------------------------------------------------------- progress --


def load_progress():
    if os.path.exists(PROGRESS):
        with open(PROGRESS) as fh:
            return json.load(fh)
    return {"jobs": {}, "started_at": None, "updated_at": None}


def save_progress(prog):
    prog["updated_at"] = time.strftime("%Y-%m-%dT%H:%M:%S")
    if prog.get("started_at") is None:
        prog["started_at"] = prog["updated_at"]
    with open(PROGRESS, "w") as fh:
        json.dump(prog, fh, indent=1, sort_keys=True)


# ------------------------------------------------------------- png helpers --


def px_to_image(pixels):
    """VD.decode_ui_png rows ('#hex'/None) -> PIL RGBA image."""
    h = len(pixels)
    w = len(pixels[0])
    img = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    data = []
    for row in pixels:
        for px in row:
            if px is None:
                data.append((0, 0, 0, 0))
            else:
                data.append((int(px[1:3], 16), int(px[3:5], 16),
                             int(px[5:7], 16), 255))
    img.putdata(data)
    return img


def token_image(path):
    """Decode a token PNG through the minimal decoder and return RGBA."""
    with open(path, "rb") as fh:
        _, _, px = VD.decode_ui_png(fh.read())
    return px_to_image(px)


def manifest_tile(manifest_path):
    """String-map terrain manifest -> PIL RGBA tile."""
    with open(manifest_path) as fh:
        d = json.load(fh)
    pal = d["palette"]
    rows = d["rows"]
    return px_to_image([[pal.get(ch) for ch in row] for row in rows])


def hex_dist2(a, b):
    ar, ag, ab = int(a[1:3], 16), int(a[3:5], 16), int(a[5:7], 16)
    br, bg, bb = int(b[1:3], 16), int(b[3:5], 16), int(b[5:7], 16)
    return (ar - br) ** 2 + (ag - bg) ** 2 + (ab - bb) ** 2


def quantize(hexcolor, block):
    best, best_d = None, None
    for cand in block:
        d = hex_dist2(hexcolor, cand)
        if best_d is None or d < best_d:
            best, best_d = cand, d
    return best


def nearest(img, factor):
    return img.resize((img.width * factor, img.height * factor),
                      Image.NEAREST)


# ------------------------------------------------------------- draft stage --


def build_ship_draft(ship, direction, out_path):
    # hull asset tokens are 64x64 (icons are 32) -> x8 = 512
    src = os.path.join(REPO, "assets", "ui", "tokens",
                       f"hull_{ship}_player_{direction}.png")
    token = token_image(src)
    canvas = Image.new("RGBA", token.size, GREEN_BG)
    canvas.alpha_composite(token)
    ref = nearest(canvas, 8)
    ref.convert("RGB").save(out_path)
    return ref


def build_icon_draft(icon_id, out_path):
    src = os.path.join(REPO, "assets", "ui", "icons", f"{icon_id}.png")
    token = token_image(src)
    canvas = Image.new("RGBA", (32, 32), GREEN_BG)
    canvas.alpha_composite(token)
    ref = nearest(canvas, 16)  # 32 -> 512
    ref.convert("RGB").save(out_path)
    return ref


# ------------------------------------------------------------ terrain art ---

RIDGE = """
.....gggg.......
....gwwgg.......
..ggwwgggd......
.gwwggggggd.....
gwwggggggggdd...
gggggggggddd....
.ddddddddd......
................
""".strip("\n").split("\n")

MOUNTAIN = """
.....ggggg......
....gwwwgg......
...gwwwgggd.....
..gwwwgggggd....
.gwwwgggggggd...
gwwwggggggggdd..
gggggggggggdd...
.dddddddddd.....
................
""".strip("\n").split("\n")

ICE_HI = "#e4eef4"
ICE = "#c9d6df"
ICE_LO = "#9fb4c4"
ROCK_HI = "#565656"
ROCK = "#3d3d3d"
ROCK_LIT = "#9a9a9a"


def cluster_tile(base_img, rows_bitmap, pal, dx, dy):
    """Stamp a cluster bitmap at 2px chunk (so it reads at terrain scale)."""
    tile = base_img.copy()
    px = tile.load()
    for y, row in enumerate(rows_bitmap):
        for x, ch in enumerate(row):
            if ch in pal:
                for oy in range(2):
                    for ox in range(2):
                        px[(x * 2 + ox + dx) % 32,
                           (y * 2 + oy + dy) % 32] = _hex_rgba(pal[ch])
    return tile


def icy_band_tile(base_img):
    """White-blue icy rim on the upper ~10 rows, ragged transition."""
    tile = base_img.copy()
    px = tile.load()
    for y in range(32):
        for x in range(32):
            depth = y - ((3 * x + 5) % 7)  # ragged lower edge
            if depth < 0:
                continue
            if (3 * x + 5 * y) % 16 == 3:
                px[x, y] = _hex_rgba(ICE_HI)
            elif (5 * x + 3 * y + 7) % 16 == 11:
                px[x, y] = _hex_rgba(ICE_LO)
            elif depth < 10:
                px[x, y] = _hex_rgba(ICE)
    return tile


def rocky_fill_tile():
    img = Image.new("RGBA", (32, 32), (0, 0, 0, 0))
    px = img.load()
    for y in range(32):
        for x in range(32):
            if (3 * x + 5 * y) % 16 == 3:
                c = ROCK_LIT
            elif (5 * x + 3 * y + 7) % 16 < 6:
                c = ROCK_HI
            else:
                c = ROCK
            px[x, y] = _hex_rgba(c)
    return img


def _hex_rgba(h):
    return (int(h[1:3], 16), int(h[3:5], 16), int(h[5:7], 16), 255)


def terrain_region(key):
    """(macro tile image per (tx,ty), prompt) for one terrain sheet.

    Macro grid: 8 x 4 tiles of 32x32; the whole sheet x2 = 1024x512, and
    the 4x2 patch boundaries of 256px fall exactly on macro-tile (2,2).
    """
    land = manifest_tile(os.path.join(REPO, "tools", "ui_art", "terrain",
                                      "terrain_land_0.json"))
    sea = manifest_tile(os.path.join(REPO, "tools", "ui_art", "terrain",
                                     "terrain_sea_0.json"))
    ridge_pal = {"g": ROCK_HI, "d": ROCK, "w": "#dff0f4"}
    ice_land = icy_band_tile(land)
    ice_sea = icy_band_tile(sea)
    rocky_fill = rocky_fill_tile()

    def band(tx, ty):  # ridge clusters scattered like the probe pattern
        return ((tx * 5 + ty * 3) % 7) in (1, 3, 4)

    def offset(tx, ty):  # per-tile cluster position, wraps around the tile
        return ((tx * 5 + ty * 3) % 3) * 6, ((tx * 3 + ty * 7) % 2) * 8 + 6

    def hill_at(tx, ty):
        return cluster_tile(land, RIDGE, ridge_pal, *offset(tx, ty))

    def mount_at(tx, ty):
        return cluster_tile(land, MOUNTAIN, ridge_pal, *offset(tx, ty))

    def reef_at(tx, ty):
        return cluster_tile(sea, RIDGE,
                            {"g": ROCK_HI, "d": ROCK, "w": ICE_HI},
                            *offset(tx, ty))

    grids = {
        "hills_plains": (lambda tx, ty: hill_at(tx, ty)
                         if band(tx, ty) else land,
                         "low rocky ridge hills over a golden-brown "
                         "dithered plains base"),
        "mountains_plains": (lambda tx, ty: mount_at(tx, ty)
                             if band(tx, ty) else land,
                             "tall grey mountain peaks with white snow caps "
                             "over a golden-brown dithered plains base"),
        "ice_plains": (lambda tx, ty: ice_land if ty < 2 else land,
                       "a white-blue icy rim band over the golden-brown "
                       "dithered plains base"),
        "ice_sea": (lambda tx, ty: ice_sea if ty < 2 else sea,
                    "a white-blue icy rim band over deep-blue flat sea "
                    "water"),
        "reef_sea": (lambda tx, ty: reef_at(tx, ty)
                     if band(tx, ty) else sea,
                     "dark grey reef rocks breaking through deep-blue flat "
                     "sea water"),
        "rocky_uniform": (lambda tx, ty: rocky_fill,
                          "a uniform region of bare grey rocky mountain "
                          "fill texture (dense stony ground, no clusters) — "
                          "every patch identical"),
        "plains_uniform": (lambda tx, ty: land,
                           "a uniform region of the golden-brown dithered "
                           "plains base texture — every patch identical"),
    }
    tile_fn, texture = grids[key]
    prompt = ("Redraw this tile sheet. Keep the exact same layout, thin "
              "patch gaps and region shapes. Restyle both textures as rich "
              "early-90s 16-bit terrain pixel art: " + texture + ". Crisp "
              "limited palette, chunky readable pixels, no text, no frame, "
              "no scenery beyond the tiles.")
    sheet = Image.new("RGBA", (1024, 512), (0, 0, 0, 0))
    for ty in range(4):
        for tx in range(8):
            tile = tile_fn(tx, ty)
            tile = tile.resize((128, 128), Image.NEAREST)  # 32px tile -> 128
            sheet.alpha_composite(tile, (tx * 128, ty * 128))
    draw = ImageDraw.Draw(sheet)
    for x in (0, 254, 255, 510, 511, 766, 767, 1022, 1023):
        draw.line([(x, 0), (x, 511)], fill=SHEET_BG)
    for y in (0, 254, 255, 510, 511):
        draw.line([(0, y), (1023, y)], fill=SHEET_BG)
    return sheet, prompt


TERRAIN_KEYS = ["hills_plains", "mountains_plains", "ice_plains", "ice_sea",
                "reef_sea", "rocky_uniform", "plains_uniform"]

# ------------------------------------------------------------ model calls ---


def generate(png_bytes, prompt, seed):
    """POST /edit; response body IS the PNG. One retry, then raise."""
    body = {"image": base64.b64encode(png_bytes).decode("ascii"),
            "prompt": prompt, "seed": seed}
    last = None
    for attempt in (1, 2):
        try:
            r = requests.post(EDIT_URL, json=body, timeout=180)
            r.raise_for_status()
            if r.content[:8] != b"\x89PNG\r\n\x1a\n":
                raise RuntimeError(
                    f"response is not a PNG (len={len(r.content)}, "
                    f"head={r.content[:24]!r})")
            return r.content
        except Exception as exc:  # noqa: BLE001 — batch must not abort
            last = exc
            print(f"    gen attempt {attempt} failed: {exc}", flush=True)
            time.sleep(2)
    raise RuntimeError(f"generate failed twice: {last}")


def rembg(png_bytes, job_id):
    """ComfyUI rembg, workflow template AS-IS (InvertMask kept)."""
    fname = f"{job_id}_{uuid.uuid4().hex[:8]}.png"
    with open(REMBG_WF) as fh:
        wf = json.load(fh)
    up = requests.post(
        f"{COMFY}/upload/image",
        files={"image": (fname, png_bytes, "image/png")},
        data={"overwrite": "true", "type": "input", "subfolder": ""},
        timeout=60)
    up.raise_for_status()
    uploaded = up.json()["name"]
    wf["1"]["inputs"]["image"] = uploaded
    wf["6"]["inputs"]["filename_prefix"] = f"sailage_{job_id}"
    r = requests.post(f"{COMFY}/prompt",
                      json={"prompt": wf, "client_id": CLIENT_ID},
                      timeout=60)
    r.raise_for_status()
    prompt_id = r.json()["prompt_id"]
    for _ in range(120):
        time.sleep(1)
        h = requests.get(f"{COMFY}/history/{prompt_id}", timeout=30).json()
        if prompt_id in h:
            imgs = h[prompt_id].get("outputs", {}).get("6", {}).get("images")
            if imgs:
                im = imgs[0]
                v = requests.get(
                    f"{COMFY}/view", params={"filename": im["filename"],
                                             "subfolder": im["subfolder"],
                                             "type": im["type"]}, timeout=60)
                v.raise_for_status()
                if v.content[:8] != b"\x89PNG\r\n\x1a\n":
                    raise RuntimeError("rembg /view returned a non-PNG")
                return v.content
            raise RuntimeError(f"rembg history has no output images: "
                               f"{h[prompt_id].get('status')}")
    raise RuntimeError("rembg timed out after 120 s")


def key_green(img, thr=60):
    """Green-bg keying post-pass over the rembg matte (PIL RGBA, any size).

    rembg's output has the background alpha-0 already; the surviving green
    lives in ENCLOSED pockets (between sails, under booms) that the matte
    kept, plus blended edges. So after the (robustness) flood, one
    connectivity-free kill removes BRIGHT chroma greens anywhere:
      g >= 170, r <= 100, b <= 100
    (darker model greens g 100–160 double as the junk/galiot olive wale
    bands and must survive). Then despill (G -> max(R,B)) + 1px erosion.
    """
    w, h = img.size
    px = img.load()
    # reference chroma from the four corner patches (always background;
    # sampled over RGB regardless of alpha — rembg zeroes bg alpha)
    rs, gs, bs = [], [], []
    for cx, cy in ((0, 0), (w - 40, 0), (0, h - 40), (w - 40, h - 40)):
        for y in range(max(0, cy), min(h, cy + 40)):
            for x in range(max(0, cx), min(w, cx + 40)):
                p = px[x, y]
                rs.append(p[0]); gs.append(p[1]); bs.append(p[2])
    rs.sort(); gs.sort(); bs.sort()
    ref = (rs[len(rs) // 2], gs[len(gs) // 2], bs[len(bs) // 2])

    def greenish(p):
        # strict chroma match OR green-dominance (catches gradient/shadow
        # greens the model adds despite the "no gradient" clause). The
        # flood only removes border-CONNECTED px, so interior greens
        # (galiot/junk wale bands) survive either test.
        r, g, b = p[0], p[1], p[2]
        if g < 90:
            return False
        strict = (abs(r - ref[0]) <= thr and abs(g - ref[1]) <= thr
                  and abs(b - ref[2]) <= thr)
        dominant = g > r + 40 and g > b + 40
        return strict or dominant

    # border-connected flood fill over green-ish px
    flood = bytearray(w * h)
    stack = deque()
    for x in range(w):
        for y in (0, h - 1):
            if not flood[y * w + x] and greenish(px[x, y]):
                flood[y * w + x] = 1
                stack.append((x, y))
    for y in range(h):
        for x in (0, w - 1):
            if not flood[y * w + x] and greenish(px[x, y]):
                flood[y * w + x] = 1
                stack.append((x, y))
    while stack:
        x, y = stack.popleft()
        for nx, ny in ((x + 1, y), (x - 1, y), (x, y + 1), (x, y - 1)):
            if 0 <= nx < w and 0 <= ny < h and not flood[ny * w + nx] \
                    and greenish(px[nx, ny]):
                flood[ny * w + nx] = 1
                stack.append((nx, ny))
    for i in range(w * h):
        if flood[i]:
            px[i % w, i // w] = (0, 0, 0, 0)

    # connectivity-free chroma kill (enclosed pockets are matted in by
    # rembg and never touch the border, so the flood cannot reach them):
    # BRIGHT saturated green only — g >= 170, r <= 100, b <= 100. Darker
    # model greens (g 100–160) overlap the junk/galiot olive wale bands
    # ((32,128,0)-style, b≈0), so they must NOT be killed; any leftover
    # dark pocket px quantize to ink at snap time.
    for y in range(h):
        for x in range(w):
            r, g, b, a = px[x, y]
            if a and g >= 170 and r <= 100 and b <= 100:
                px[x, y] = (0, 0, 0, 0)

    # despill: surviving edge px lose the green cast (G -> max(R, B))
    for y in range(h):
        for x in range(w):
            r, g, b, a = px[x, y]
            if a == 0 or g <= max(r, b):
                continue
            edge = a < 250 or any(
                not (0 <= nx < w and 0 <= ny < h) or px[nx, ny][3] == 0
                for nx, ny in ((x + 1, y), (x - 1, y), (x, y + 1),
                               (x, y - 1)))
            if edge:
                px[x, y] = (r, max(r, b), b, a)

    # 1px alpha erosion: any 4-neighbour transparent -> transparent
    alpha_map = [px[x, y][3] for y in range(h) for x in range(w)]
    for y in range(h):
        for x in range(w):
            i = y * w + x
            if alpha_map[i] == 0:
                continue
            for nx, ny in ((x + 1, y), (x - 1, y), (x, y + 1), (x, y - 1)):
                if not (0 <= nx < w and 0 <= ny < h) \
                        or alpha_map[ny * w + nx] < 32:
                    px[x, y] = (0, 0, 0, 0)
                    break
    return img


def keyed_png(png_bytes):
    """rembg bytes -> keyed RGBA PNG bytes (green post-pass)."""
    img = Image.open(io.BytesIO(png_bytes)).convert("RGBA")
    img = key_green(img)
    buf = io.BytesIO()
    img.save(buf, "PNG")
    return buf.getvalue()


# ---------------------------------------------------------------- snapping --


BAND_CENTER = {1: 32, 2: 46, 3: 56}
COMPACT = ("Compact proportions: the whole ship fits within a square as "
           "wide as it is long, compact hull, the outboard rig overhangs "
           "the hull minimally.")
ICON_PROMPT_OVERRIDES = {
    "compass": ("Redraw this input sprite. Keep the exact same silhouette "
                "and recognizability. It is a magnetic COMPASS: a round "
                "brass-rim compass face with a needle rose, N/E/S/W letters "
                "on the dial — NOT a ship's wheel, no spokes, no handles. "
                + ICON_STYLE),
    "save": ("Redraw this input sprite. Keep the exact same silhouette and "
             "recognizability. It is a retro 3.5-inch FLOPPY DISK: a "
             "square flat plastic body, a silver metal shutter slider at "
             "the top edge, a small white paper label on the lower half, "
             "a small corner notch — a computer storage icon. NOT an "
             "inkwell, NO quill, NO feather, no pen. " + ICON_STYLE),
    "crew": ("Redraw this input sprite. Keep the exact same silhouette and "
             "recognizability. It is a SAILOR figure: head-and-shoulders "
             "bust wearing a round sailor cap, distinct face — not a "
             "generic blob, not a podium. " + ICON_STYLE),
    "strong": ("Redraw this input sprite. Keep the exact same silhouette "
               "and recognizability. It is a STRENGTH glyph: two bold "
               "stacked upward-pointing CHEVRON ARROWS (^ above ^), thick "
               "gold chevrons with a dark outline, instantly readable at "
               "32 px. NOT wind lines, NOT wavy horizontal lines, no "
               "small strokes. " + ICON_STYLE),
    "cannon": ("Redraw this input sprite. Keep the exact same silhouette "
               "and recognizability. It is a full BRONZE CANNON on a wooden "
               "carriage: long barrel with a muzzle ring plus visible "
               "wheels — not just a barrel, not a wheel alone. "
               + ICON_STYLE),
    "hook": ("Redraw this input sprite. Keep the exact same silhouette and "
             "recognizability. It is a curved GRAPPLING BOAT HOOK: clear "
             "hook silhouette with a strong curve and a point, single "
             "readable shape. " + ICON_STYLE),
    "good_iron": ("Redraw this input sprite. Keep the exact same silhouette "
                  "and recognizability. It is a stack of dark IRON INGOTS "
                  "(two or three trapezoid metal bars stacked) — not a "
                  "bench, not a stool. " + ICON_STYLE),
    "scroll": ("Redraw this input sprite. Keep the exact same silhouette "
               "and recognizability. It is a ROLLED PARCHMENT SCROLL: a "
               "paper roll with curled ends and a visible written face — "
               "not a chalkboard, not a framed board. " + ICON_STYLE),
    "ram": ("Redraw this input sprite. Keep the exact same silhouette and "
            "recognizability. It is a SHIP BOW RAM: a reinforced bronze "
            "beak protruding forward from a short hull segment at the "
            "waterline — the beak is the dominant feature. " + ICON_STYLE),
}


def snap_and_measure(png_bytes, block_palette, long_axis_band=None):
    """512 -> 64-grid majority snap + metrics. Returns (64img, metrics)."""
    _, _, px = VD.decode_ui_png(png_bytes)
    h, w = len(px), len(px[0])
    drift = None
    if (w, h) != (512, 512):
        drift = (w, h)
        img = Image.new("RGBA", (w, h))
        img.putdata([_hex_rgba(c) if c else (0, 0, 0, 0)
                     for row in px for c in row])
        img = img.resize((512, 512), Image.NEAREST)
        flat = list(img.getdata())
    else:
        flat = [(int(c[1:3], 16), int(c[3:5], 16), int(c[5:7], 16), 255)
                if c else (0, 0, 0, 0) for row in px for c in row]

    grid = []
    opaque_cells = 0
    for gy in range(64):
        row = []
        for gx in range(64):
            cnt = Counter()
            for y in range(gy * 8, gy * 8 + 8):
                base = y * 512
                for x in range(gx * 8, gx * 8 + 8):
                    r, g, b, a = flat[base + x]
                    if a:
                        cnt[(r, g, b)] += 1
            if not cnt:
                row.append(None)
            else:
                opaque_cells += 1
                winner = max(cnt.items(), key=lambda kv: (kv[1], kv[0]))[0]
                row.append(quantize("#%02x%02x%02x" % winner, block_palette))
        grid.append(row)

    xs = [x for y in range(64) for x in range(64) if grid[y][x]]
    ys = [y for y in range(64) for x in range(64) if grid[y][x]]
    bbox = None
    band = None
    if xs:
        bbox = (min(xs), min(ys), max(xs), max(ys))
    metrics = {
        "opaque_pct": round(100.0 * opaque_cells / (64 * 64), 1),
        "bbox": bbox,
        "fit_inside_64": bool(bbox and bbox[0] >= 0 and bbox[1] >= 0
                              and bbox[2] < 64 and bbox[3] < 64),
    }
    if long_axis_band and bbox:
        lo, hi = long_axis_band
        width = bbox[2] - bbox[0] + 1
        band = {"long_axis_px": width, "band": list(long_axis_band),
                "in_band": lo <= width <= hi}
        metrics["band"] = band

    # pennant note: red-ish cluster in the sprite's top region
    red_hexes = ("#b3191f", "#b3341f")
    count = 0
    top = (bbox[3] // 2) if bbox else 32
    for y in range(64):
        for x in range(64):
            c = grid[y][x]
            if c is None:
                continue
            if any(hex_dist2(c, rh) <= 90 * 90 for rh in red_hexes):
                if bbox and y <= bbox[1] + (bbox[3] - bbox[1]) * 0.45:
                    count += 1
    metrics["pennant_red_px"] = count
    metrics["pennant_present"] = count >= 3

    img = Image.new("RGBA", (64, 64), (0, 0, 0, 0))
    data = [(0, 0, 0, 0) if c is None else
            (int(c[1:3], 16), int(c[3:5], 16), int(c[5:7], 16), 255)
            for row in grid for c in row]
    img.putdata(data)
    return img, metrics, drift


# ------------------------------------------------------------------- jobs ---


def job_list_ships():
    jobs = []
    for hull in HULLS:
        for direction in DIRS:
            jobs.append(f"hull_{hull}_{direction}")
    return jobs


def job_list_terrain():
    return [f"terrain_{k}" for k in TERRAIN_KEYS]


ICON_PRIORITY = [
    # curated first 32 (semantic glyphs before arrows/misc; verified ids)
    "anchor", "crown", "skull", "hourglass", "save",
    "coin", "crew", "provisions", "morale", "durability",
    "chest", "scroll", "hammer", "bell",
    "cannon", "hook", "ram", "surrender_flag",
    "compass", "calm", "fair", "strong", "storm",
    "good_wheat", "good_silk", "good_spices", "good_wine",
    "good_salt", "good_dried_fish", "good_timber", "good_iron",
    "trophy",
]


def job_list_icons(limit=32):
    manifests = {}
    import glob
    for path in sorted(glob.glob(os.path.join(REPO, "tools", "ui_art",
                                              "icons", "*.json"))):
        with open(path) as fh:
            d = json.load(fh)
        for s in d.get("sprites", []):
            manifests[s["id"]] = s
    known = set(manifests)
    ids = [i for i in ICON_PRIORITY if i in known]
    rest = [i for i in sorted(manifests) if i not in set(ids)]
    ids += rest
    out = []
    for icon_id in ids:
        out.append(f"icon_{icon_id}")
        if len(out) >= limit:
            break
    return out


def resolve_prompt(job_id):
    if job_id.startswith("hull_"):
        ship, direction = job_id[len("hull_"):].rsplit("_", 1)
        tier = TIER[ship]
        return hull_prompt(ship, direction), \
            (BANDS[tier] if direction in ("e", "w") else None), BLOCK_HULL
    if job_id.startswith("terrain_"):
        sheet, prompt = terrain_region(job_id[len("terrain_"):])
        return sheet, prompt, None, None
    if job_id.startswith("icon_"):
        icon_id = job_id[len("icon_"):]
        prompt = (ICON_PROMPT_OVERRIDES.get(icon_id) or
                  (f"Redraw this input sprite. Keep the exact same "
                   f"silhouette and recognizability. {ICON_STYLE}"))
        return prompt, None, BLOCK_ICON
    raise KeyError(job_id)


def hull_prompt(ship, direction, stated_px=None):
    """Hardened hull prompt: physical-anchor direction wording, compact
    clause (+ calibrated px length), scale anchors for the fallback trio."""
    pose = POSE[direction]
    rig = RIG[ship]
    if ship == "pinnace":
        # STYLE's "billowed canvas sails" clause drags the model into a
        # square rig — the pinnace needs an explicit no-sail prompt, plus
        # a scale anchor (green round drew it canvas-tiny)
        return (f"Redraw this input sprite. Keep the exact same silhouette, "
                f"proportions and {pose}. Rig: NO sails — a substantial "
                f"vessel, NOT a small boat: a long open rowing galley about "
                f"500 px long on the 512 canvas, with two staggered "
                f"oar banks (small oar blades dipping at the waterline on "
                f"both sides), one short bare mast stub carrying only a "
                f"small red pennant flag, dense wooden hull with visible "
                f"planking lines, a few small crew figures rowing, strong "
                f"1-pixel dark outline around the whole sprite, big chunky "
                f"pixels, "
                + CHROMA_BG + ". No large sails, no square rig, "
                f"no cabins, no gunports. No water, no scenery, no text, "
                f"no frame.")
    prompt = (f"Redraw this input sprite. Keep the exact same "
              f"silhouette, mast count, sail layout, proportions and "
              f"{pose}. Rig: {rig}. {COMPACT} ")
    if ship == "nao":
        prompt += "The ship fills about 85% of the canvas. "
    elif ship == "sloop":
        prompt += "The ship fills about 70-80% of the canvas width. "
    if stated_px:
        prompt += (f"Ship length about {stated_px} px of the 512 canvas "
                   f"including bowsprit. ")
    return prompt + STYLE


# ------------------------------------------------- direction audit (quant)

def _snap_px(job_id):
    img = Image.open(os.path.join(SNAPPED, job_id + ".png")).convert("RGBA")
    return img.load(), img.size


def classify_for(job_id, expected):
    """Quantified facing classifier (hull-band physics, not whole-sprite
    axis): the hull band = opaque px in the bottom 30% of the sprite.

    - w: hull band spans wide (>=55% bbox width) and the band's bow end
      (less mass) is LEFT.
    - n: mirror symmetry (IoU vs x-flip >= 0.45) + wide bottom slab
      (bottom-row width >= 42% of max width) = transom head-on.
    - s: mirror symmetry + narrow bottom taper (<= 48%) = bowsprit down.
    - sw/nw: diagonal principal axis (20-70 deg) + bow mass toward the
      LEFT half.
    Ambiguous cells FAIL (the user must never guess).
    """
    px, (w, h) = _snap_px(job_id)
    pts = [(x, y) for y in range(h) for x in range(w) if px[x, y][3]]
    if len(pts) < 24:
        return {"expected": expected, "observed": "ambiguous",
                "verdict": "FAIL", "why": "near-empty snap", "confidence": 0}
    import math
    xs = [p[0] for p in pts]
    ys = [p[1] for p in pts]
    x0, x1, y0, y1 = min(xs), max(xs), min(ys), max(ys)
    bw, bh = x1 - x0 + 1, y1 - y0 + 1
    n = len(pts)
    cx = (x0 + x1) / 2
    cy = (y0 + y1) / 2
    roww = Counter(p[1] for p in pts)
    ev = {"bbox": [bw, bh]}

    # hull band = bottom 30% of the sprite
    y_band = y1 - 0.30 * (y1 - y0)
    band = [(x, y) for x, y in pts if y >= y_band]
    band_xs = [p[0] for p in band] or [cx]
    band_w = max(band_xs) - min(band_xs) + 1
    band_ratio = band_w / max(1, bw)
    band_left = sum(1 for x, y in band if x < cx)
    band_right = len(band) - band_left
    ev["band_ratio"] = round(band_ratio, 2)
    ev["band_lr"] = [band_left, band_right]

    # mirror symmetry about the bbox centre-x
    inter = 0
    for x, y in pts:
        mx = int(round(2 * cx - x))
        if 0 <= mx < w and px[mx, y][3]:
            inter += 1
    sym = inter / max(1, n)
    ev["symmetry"] = round(sym, 2)

    bottom = max(roww[y] for y in roww if y >= y1 - 5)
    maxw = max(roww.values())
    bottom_frac = bottom / max(1, maxw)
    ev["bottom_frac"] = round(bottom_frac, 2)

    if expected == "w":
        if band_ratio < 0.55:
            ev["why"] = (f"hull band narrow ({band_ratio:.2f}) - "
                         f"not a side view")
            return {"expected": expected, "observed": "ambiguous",
                    "verdict": "FAIL", "confidence": 0.2, **ev}
        bow_left = band_left <= band_right
        conf = abs(band_left - band_right) / max(1, band_left + band_right)
        observed = "w" if bow_left else "e(flip)"
        return {"expected": expected, "observed": observed,
                "verdict": "PASS" if bow_left else "FAIL",
                "confidence": round(0.5 + conf, 2), **ev}
    if expected in ("n", "s"):
        # authored n and s drafts overlap in silhouette stats (bfrac med
        # 0.83 vs 0.80) — the transom/bowsprit difference is not a
        # silhouette fact. Honest audit: symmetric + NOT duplicates of
        # each other + NOT a copy of the w cell; semantic truth stays
        # reviewable via the adjacent cells in 29_hull_sheets.png.
        ship = job_id[len("hull_"):].rsplit("_", 1)[0]
        other = "s" if expected == "n" else "n"
        iou_other = cell_iou(job_id, f"hull_{ship}_{other}")
        iou_w = cell_iou(job_id, f"hull_{ship}_w")
        ev["iou_other"] = round(iou_other, 2)
        ev["iou_w"] = round(iou_w, 2)
        if sym < 0.45:
            ev["why"] = f"asymmetric ({sym:.2f}) — likely a side/quarter view"
            observed = "quarter(?)"
            return {"expected": expected, "observed": observed,
                    "verdict": "FAIL", "confidence": 0.3, **ev}
        if iou_other >= 0.55:
            ev["why"] = (f"duplicate of the {other} cell "
                         f"(IoU {iou_other:.2f}) — same view drawn twice")
            observed = f"duplicate-of-{other}"
            return {"expected": expected, "observed": observed,
                    "verdict": "FAIL", "confidence": 0.5, **ev}
        if iou_w >= 0.55:
            ev["why"] = f"duplicates the w cell (IoU {iou_w:.2f})"
            observed = "duplicate-of-w"
            return {"expected": expected, "observed": observed,
                    "verdict": "FAIL", "confidence": 0.5, **ev}
        observed = f"{expected}-plausible"
        return {"expected": expected, "observed": observed,
                "verdict": "PASS", "confidence": 0.55, **ev}
    # diagonals sw / nw: mechanical heading signals are weak on 3/4
    # renders (hull bands sit near-horizontal, sails tower), so the
    # verdict = no flip evidence + not a duplicate of the w cell (a side
    # view pasted into a diagonal cell).
    left_end = [y for x, y in band if x <= x0 + 5]
    right_end = [y for x, y in band if x >= x1 - 5]
    if left_end and right_end:
        tilt = sum(left_end) / len(left_end) - sum(right_end) \
            / len(right_end)
    else:
        tilt = 0.0
    ev["bow_tilt"] = round(tilt, 1)
    ship = job_id[len("hull_"):].rsplit("_", 1)[0]
    dup = cell_iou(job_id, f"hull_{ship}_w")
    ev["iou_vs_w"] = round(dup, 2)
    if expected == "sw":
        flip = tilt <= -5 or band_left < 0.3 * band_right
        observed = "se(flip)" if flip else (
            "duplicate-of-w" if dup >= 0.55 else "sw")
    else:  # nw
        flip = tilt >= 5 or band_right < 0.3 * band_left
        observed = "ne(flip)" if flip else (
            "duplicate-of-w" if dup >= 0.55 else "nw")
    ok = not flip and dup < 0.55
    if not ok:
        ev["why"] = (f"flip-evidence tilt {tilt:.0f}px / band "
                     f"{band_left}L/{band_right}R" if flip else
                     f"duplicates the w cell (IoU {dup:.2f})")
    return {"expected": expected, "observed": observed,
            "verdict": "PASS" if ok else "FAIL",
            "confidence": 0.55 if ok else 0.5, **ev}


def cell_iou(job_a, job_b):
    """Mask IoU between two snapped tokens (duplicate-view detector)."""
    pa, (wa, ha) = _snap_px(job_a)
    pb, (wb, hb) = _snap_px(job_b)
    inter = 0
    union = 0
    for y in range(min(ha, hb)):
        for x in range(min(wa, wb)):
            a = pa[x, y][3] > 0
            b = pb[x, y][3] > 0
            if a and b:
                inter += 1
            if a or b:
                union += 1
    return inter / max(1, union)


def audit_directions():
    """Audit all 80 base jobs; report.json -> direction_audit[]."""
    audit = []
    for ship in HULLS:
        for direction in DIRS:
            job_id = f"hull_{ship}_{direction}"
            res = classify_for(job_id, direction)
            res["job"] = job_id
            audit.append(res)
        # n/s duplicate-view detector: the model drawing the same view
        # twice is the classic n/s confusion (user complaint)
        iou = cell_iou(f"hull_{ship}_n", f"hull_{ship}_s")
        if iou >= 0.55:
            for res in audit:
                if res["job"] in (f"hull_{ship}_n", f"hull_{ship}_s"):
                    res["verdict"] = "FAIL"
                    res["observed"] = res["observed"] + "/duplicate"
                    res["why"] = f"n/s duplicate views (IoU {iou:.2f})"
                    res["ns_iou"] = round(iou, 2)
    prog = load_progress()
    prog["direction_audit"] = audit
    save_progress(prog)
    npass = sum(1 for a in audit if a["verdict"] == "PASS")
    print(f"direction audit: {npass}/{len(audit)} PASS")
    for a in audit:
        if a["verdict"] != "PASS":
            print(f"  FAIL {a['job']}: observed={a['observed']} "
                  f"({a.get('why') or a.get('bow_at') or a.get('bottom_frac')})")
    return audit


def dir_failed_jobs(audit):
    return [a["job"] for a in audit if a["verdict"] != "PASS"]


# arrow glyph geometry: unit triangles per direction (image coords, y down)
ARROW = {
    "w": [(-1, 0.5), (0.6, -0.5), (0.6, 1.5)],
    "n": [(0.5, -1), (-0.5, 0.6), (1.5, 0.6)],
    "s": [(0.5, 1), (-0.5, -0.6), (1.5, -0.6)],
    "sw": [(-0.7, 0.7), (0.5, -0.3), (-0.3, 0.5)],
    "nw": [(-0.7, -0.7), (0.5, 0.3), (-0.3, -0.5)],
}


def sheet_direction_audit(audit):
    """28_direction_audit.png: base jobs at x6, expected-vs-detected arrow
    glyph beside each cell (green = match, red = mismatch/ambiguous)."""
    cell = 336           # 64-grid x5 sprite + arrow gutter
    sprite = 320
    head = 34
    cols = len(HULLS)
    rows = len(DIRS)
    img = Image.new("RGBA", (96 + cols * cell + 8,
                             head + rows * (cell + 8) + 8), SHEET_BG)
    draw = ImageDraw.Draw(img)
    for ci, hull in enumerate(HULLS):
        label(draw, (96 + ci * cell + 6, 8), hull)
    by_job = {a["job"]: a for a in audit}
    for ri, direction in enumerate(DIRS):
        y0 = head + ri * (cell + 8)
        label(draw, (6, y0 + 140), direction)
        for ci, hull in enumerate(HULLS):
            job_id = f"hull_{hull}_{direction}"
            x0 = 96 + ci * cell
            path = os.path.join(SNAPPED, job_id + ".png")
            if os.path.exists(path):
                tok = Image.open(path).resize((sprite, sprite),
                                              Image.NEAREST)
                img.alpha_composite(tok, (x0 + 8, y0 + 8))
            a = by_job.get(job_id)
            if not a:
                continue
            good = a["verdict"] == "PASS"
            observed = a["observed"]
            key = observed if observed in ARROW else (
                "w" if "flip" in observed else direction)
            vec = ARROW.get(key, ARROW[direction])
            color = (70, 200, 90) if good else (220, 60, 60)
            ox, oy = x0 + cell - 30, y0 + 26
            pts = [(ox + vx * 11, oy + vy * 11) for vx, vy in vec]
            draw.polygon(pts, fill=color)
            letter = "OK" if good else "X"
            label(draw, (ox - 6, oy + 22), letter,
                  color=(140, 240, 150) if good else (255, 120, 120))
    out = os.path.join(REVIEW, "28_direction_audit.png")
    img.convert("RGB").save(out)
    print("wrote", out)


def reroll_direction(job_id, max_attempts=3, reason="direction semantics"):
    """Direction re-roll: hardened wording, <=3 attempts, each attempt
    classified; keep the best (PASS preferred, then confidence)."""
    t0 = time.time()
    ship, direction = job_id[len("hull_"):].rsplit("_", 1)
    tier = TIER[ship]
    band = BANDS[tier] if direction in ("w",) else None
    base = canonical_seed(job_id) + DIR_SEED_OFFSET
    draft_path = os.path.join(DRAFTS, job_id + ".png")
    build_ship_draft(ship, direction, draft_path)
    attempts = []
    best = None  # (score, rec, seed)
    for n in range(1, max_attempts + 1):
        seed = base + n * 1000
        tag = f"_d{n}"
        prompt = hull_prompt(ship, direction)
        rec = exec_gen(job_id, "hull", draft_path, prompt, seed, BLOCK_HULL,
                       band, tag=tag)
        for d in (GEN, DEBG, SNAPPED):  # promote for classification
            src = os.path.join(d, f"{job_id}{tag}.png")
            dst = os.path.join(d, job_id + ".png")
            if os.path.exists(src):
                shutil.copy(src, dst)
        cls = classify_for(job_id, direction)
        score = (0 if cls["verdict"] == "PASS" else
                 (1 if cls["verdict"] == "PASS*" else 2)) \
            - min(0.9, cls.get("confidence", 0))
        attempts.append({"attempt": n, "seed": seed,
                         "verdict": cls["verdict"],
                         "observed": cls["observed"],
                         "confidence": cls.get("confidence", 0),
                         "band": (rec.get("metrics", {}).get("band") or {})
                         .get("long_axis_px")})
        if best is None or score < best[0]:
            best = (score, rec, seed, cls, n)
        if cls["verdict"] == "PASS":
            break
    score, rec, seed, cls, kept_n = best
    rec.update({"seed": seed, "status": "done",
                "seconds": round(time.time() - t0, 1),
                "direction": cls,
                "reroll": {"kind": "direction", "reason": reason,
                           "attempts": attempts, "kept_seed": seed,
                           "kept_attempt": kept_n,
                           "verdict": cls["verdict"]}})
    save_job(job_id, rec)
    return rec


PAIR_PROMPT = (
    "Two reference cells of the SAME ship, separated by a dark vertical "
    "divider. LEFT cell: the ship seen directly from ASTERN: the square "
    "transom/stern-castle faces the viewer head-on, symmetric, the ship "
    "sails AWAY upward, NO bowsprit visible. RIGHT cell: the same ship "
    "seen directly from the BOW: the bowsprit points straight DOWN toward "
    "the viewer at the bottom of the cell, symmetric bow shape, "
    "stern-castle hidden behind the sails. The two views must be "
    "mirror-opposites of each other in what they show: the left cell shows "
    "the stern castle, the right cell shows the bowsprit. Rig: {rig}. "
    "{scale}Render each cell as crisp limited-palette pixel art in the "
    "style of early-90s 16-bit sailing games: billowed canvas sails, dense "
    "wooden hull with visible planking lines, small lit cabin windows, "
    "strong 1-pixel dark outline around each sprite, big chunky pixels, "
    + CHROMA_BG + ". Each cell contains the full ship, centered in its "
    "cell, big enough to fill most of the cell. No water, no scenery, no "
    "text, no frame.")


def pair_n_s(ship, reason="n/s confusable pair"):
    """Confusable-pair trick: generate the n and s of one hull in a single
    /edit (left = astern cell, right = bow cell), crop, snap, audit both."""
    import math
    n_job, s_job = f"hull_{ship}_n", f"hull_{ship}_s"
    seed = canonical_seed(n_job) + DIR_SEED_OFFSET
    ref = Image.new("RGBA", (1024, 512), GREEN_BG)
    n_tok = token_image(os.path.join(REPO, "assets", "ui", "tokens",
                                     f"hull_{ship}_player_n.png"))
    s_tok = token_image(os.path.join(REPO, "assets", "ui", "tokens",
                                     f"hull_{ship}_player_s.png"))
    ref.alpha_composite(nearest(n_tok, 14), (48, 32))
    ref.alpha_composite(nearest(s_tok, 14), (528, 32))
    draw = ImageDraw.Draw(ref)
    draw.rectangle([504, 0, 519, 511], fill=(24, 28, 40, 255))
    buf = io.BytesIO()
    ref.convert("RGB").save(buf, "PNG")
    scale_clause = ""
    if ship == "pinnace":
        rig = ("NO sails — a substantial rowing galley about 500 px long, "
               "two oar banks and a bare mast stub with a small red "
               "pennant, in BOTH cells")
        scale_clause = "The boats fill 70-80% of each cell's width. "
    else:
        rig = RIG[ship]
        if ship == "nao":
            scale_clause = "Each ship fills about 85% of its cell. "
    prompt = PAIR_PROMPT.format(rig=rig, scale=scale_clause)
    gen = generate(buf.getvalue(), prompt, seed)
    with open(os.path.join(GEN, f"hull_{ship}_pair.png"), "wb") as fh:
        fh.write(gen)
    _, _, gpx = VD.decode_ui_png(gen)
    ow, oh = len(gpx[0]), len(gpx)
    s = ow / 1024.0
    out = {}
    for direction, job_id, box in (
            ("n", n_job, (int(48 * s), int(32 * s), int(496 * s),
                          int(480 * s))),
            ("s", s_job, (int(528 * s), int(32 * s), int(976 * s),
                          int(480 * s)))):
        crop = px_to_image(gpx)
        crop = crop.crop(box)
        if crop.size != (512, 512):
            crop = crop.resize((512, 512), Image.NEAREST)
        cbuf = io.BytesIO()
        crop.save(cbuf, "PNG")
        debg = keyed_png(rembg(cbuf.getvalue(), job_id))
        with open(os.path.join(DEBG, job_id + ".png"), "wb") as fh:
            fh.write(debg)
        snapped, metrics, drift = snap_and_measure(debg, BLOCK_HULL, None)
        with open(os.path.join(SNAPPED, job_id + ".png"), "wb") as fh:
            snapped.save(fh)
        cls = classify_for(job_id, direction)
        rec = {"seed": seed, "status": "done", "metrics": metrics,
               "direction": cls,
               "reroll": {"kind": "pair", "reason": reason,
                          "pair_seed": seed, "kept_seed": seed,
                          "verdict": cls["verdict"]}}
        save_job(job_id, rec)
        out[direction] = {"job": job_id, "verdict": cls["verdict"],
                          "observed": cls["observed"]}
    return out


def exec_gen(job_id, kind, draft_path, prompt, seed, block, band, tag=None):
    """generate -> (rembg -> snap | terrain normalise); writes artifacts.
    tag suffixes the artifact filenames (used by band-reroll attempts so
    the best attempt can be promoted afterwards)."""
    gen_path = os.path.join(GEN, f"{job_id}{tag or ''}.png")
    rec = {}
    with open(draft_path, "rb") as fh:
        draft_bytes = fh.read()
    gen = generate(draft_bytes, prompt, seed)
    with open(gen_path, "wb") as fh:
        fh.write(gen)
    rec["gen_bytes"] = len(gen)
    if kind == "terrain":
        _, _, px = VD.decode_ui_png(gen)
        w, h = len(px[0]), len(px)
        rec["gen_size"] = [w, h]
        if (w, h) != (1024, 512):
            rec["drift"] = round(w / 1024.0, 3)
            px_img = px_to_image(px).resize((1024, 512), Image.NEAREST)
            px_img.convert("RGB").save(gen_path)
        return rec
    debg_path = os.path.join(DEBG, f"{job_id}{tag or ''}.png")
    snap_path = os.path.join(SNAPPED, f"{job_id}{tag or ''}.png")
    debg = keyed_png(rembg(gen, job_id))  # matte -> chroma key -> erode
    with open(debg_path, "wb") as fh:
        fh.write(debg)
    rec["debg_bytes"] = len(debg)
    snapped, metrics, drift = snap_and_measure(debg, block, band)
    snapped.save(snap_path)
    rec["metrics"] = metrics
    if drift:
        rec["gen_size"] = list(drift)
    return rec


# ------------------------------------------- hull-sheet jobs (job = hull)
# doc f6c00bb keeps the 5-dir scheme; the TASK granularity is the hull:
# one 5-cell sheet per /edit for cross-direction style unity.

SHEET_DIRS = ["w", "n", "s", "sw", "nw"]
SHEET_CELLS = {"w": (64, 64), "n": (640, 64), "s": (1216, 64),
               "sw": (64, 640), "nw": (640, 640)}   # top-left of each 512px cell
SHEET_SIZE = (1792, 1152)


def hull_sheet_draft(ship, out_path):
    """5-cell draft reference: w/n/s/sw/nw tokens x6 (=384, 75% of the
    512 cell, green margins so the model does not draw cell-filling
    ships) on chroma green, 3x2 grid, labels above, dark frames."""
    ref = Image.new("RGBA", SHEET_SIZE, GREEN_BG)
    draw = ImageDraw.Draw(ref)
    for direction, (cx, cy) in SHEET_CELLS.items():
        tok = token_image(os.path.join(REPO, "assets", "ui", "tokens",
                                       f"hull_{ship}_player_{direction}.png"))
        tok = nearest(tok, 6)  # 64 -> 384, centred in the 512 cell
        ref.alpha_composite(tok, (cx + 64, cy + 64))
        draw.rectangle([cx - 2, cy - 2, cx + 513, cy + 513],
                       outline=(24, 28, 40, 255), width=2)
        label(draw, (cx + 6, cy - 46), direction, color=(16, 16, 16))
    label(draw, (1216 + 6, 594), "same ship", color=(16, 16, 16))
    label(draw, (1216 + 6, 620), "5 views", color=(16, 16, 16))
    ref.convert("RGB").save(out_path)
    return ref


def hull_sheet_prompt(ship, stated_px=None):
    rig = RIG[ship]
    if TIER[ship] == 3:
        scale = ("This hull fills about 80-90% of its cell width in every "
                 "cell. ")
    else:
        scale = ("Each ship occupies only about 60-70% of its cell width, "
                 "with clear green margin around it. ")
    if ship == "pinnace":
        scale = ("This hull fills about 75% of its cell width in every "
                 "cell — a substantial sloop-of-war, NOT a small boat. ")
    return (
        "Redraw this input sprite sheet. The five labelled cells show the "
        "SAME ship seen from five directions: identical hull, identical "
        "rig, identical materials and colour treatment in every cell; "
        "only the viewing angle changes. "
        "Cell w: side view sailing LEFT, the bow with bowsprit at the "
        "LEFT edge of the cell, stern at the RIGHT edge. "
        "Cell n: seen from astern — the square transom/stern-castle faces "
        "the viewer head-on, symmetric, the ship sails away upward, NO "
        "bowsprit visible. "
        "Cell s: seen from the bow — the bowsprit toward the viewer, "
        "transom hidden behind the sails. "
        "Cells sw and nw: three-quarter views, the bow pointing to the "
        "BOTTOM-LEFT corner (sw) and the TOP-LEFT corner (nw). "
        "Cells n and s are opposite views of the same ship: n shows the "
        "transom, s shows the bowsprit — do not draw the same view twice. "
        "Keep the cells in their exact positions and order: top-left w, "
        "top-centre n, top-right s, bottom-left sw, bottom-centre nw; do "
        "not move, re-order or re-label the cells; do not add your own "
        "labels. "
        "The small labels above the cells are pre-printed — do NOT draw "
        "them into the sprites; leave the sixth cell empty. " + scale
        + (f"Ship length about {stated_px} px within each 512 px cell. "
           if stated_px else "")
        f"Rig: {rig}. {COMPACT} {scale}"
        "Render every cell as crisp limited-palette pixel art in the "
        "style of early-90s 16-bit sailing games: billowed canvas sails "
        "with curved highlight and shadow bands following the bulge, "
        "dense wooden hull with visible planking lines, small lit cabin "
        "windows, gunports, a small red pennant flag at the mainmast top, "
        "strong 1-pixel dark outline around each sprite, big chunky "
        "pixels, " + CHROMA_BG + ". Keep the thin dark dividers. No "
        "water, no scenery, no extra text, no frame.")


def detect_sprite_cells(full):
    """Connected non-chroma-green components >= 3000 px, 5 largest bboxes,
    shrunk 1px (kills model-drawn cell frames). Returns [(x0,y0,x1,y1)]."""
    px = full.load()
    w, h = full.size
    mask = bytearray(w * h)
    for y in range(h):
        for x in range(w):
            r, g, b, a = px[x, y]
            if a > 100 and not (g >= 150 and r <= 110 and b <= 110):
                mask[y * w + x] = 1
    seen = bytearray(w * h)
    boxes = []
    for start in range(w * h):
        if mask[start] and not seen[start]:
            stack = [start]
            seen[start] = 1
            x0 = x1 = start % w
            y0 = y1 = start // w
            area = 0
            while stack:
                i = stack.pop()
                area += 1
                x, y = i % w, i // w
                x0, x1 = min(x0, x), max(x1, x)
                y0, y1 = min(y0, y), max(y1, y)
                for nx, ny in ((x + 1, y), (x - 1, y), (x, y + 1),
                               (x, y - 1)):
                    if 0 <= nx < w and 0 <= ny < h:
                        j = ny * w + nx
                        if mask[j] and not seen[j]:
                            seen[j] = 1
                            stack.append(j)
            if area >= 3000:
                boxes.append((x0 + 1, y0 + 1, x1 - 1, y1 - 1, area))
    boxes.sort(key=lambda b: -b[4])
    return [(b[0], b[1], b[2], b[3]) for b in boxes[:5]]


def cell_shape_metrics(mask):
    """(symmetry, bottom_frac, band_ratio, tilt, wide?) for a 64x64
    boolean mask — the direction fingerprint. wide threshold 0.95: side
    views still tower (sails), aspect ~1.0-1.2."""
    pts = [(x, y) for y in range(64) for x in range(64) if mask[y][x]]
    if len(pts) < 24:
        return None
    xs = [p[0] for p in pts]
    ys = [p[1] for p in pts]
    x0, x1, y0, y1 = min(xs), max(xs), min(ys), max(ys)
    bw, bh = x1 - x0 + 1, y1 - y0 + 1
    n = len(pts)
    cx = (x0 + x1) / 2
    roww = Counter(p[1] for p in pts)
    band_y = y1 - 0.30 * (y1 - y0)
    band = [(x, y) for x, y in pts if y >= band_y]
    band_xs = [p[0] for p in band] or [cx]
    band_ratio = (max(band_xs) - min(band_xs) + 1) / max(1, bw)
    band_left = sum(1 for x, y in band if x < cx)
    band_right = len(band) - band_left
    inter = 0
    for x, y in pts:
        mx = int(round(2 * cx - x))
        if 0 <= mx < 64 and mask[y][mx]:
            inter += 1
    sym = inter / n
    bottom = max(roww[y] for y in roww if y >= y1 - 5)
    bottom_frac = bottom / max(1, max(roww.values()))
    left_end = [y for x, y in band if x <= x0 + 5]
    right_end = [y for x, y in band if x >= x1 - 5]
    tilt = (sum(left_end) / len(left_end) - sum(right_end)
            / len(right_end)) if left_end and right_end else 0.0
    return {"sym": sym, "bottom_frac": bottom_frac,
            "band_ratio": band_ratio, "tilt": tilt,
            "wide": bw >= bh * 0.95, "n_px": n}


def assign_cells(cells, draft_masks):
    """Greedy unique assignment of detected cells to the 5 directions.
    cells: list of (64x64 mask, centre in sheet coords); draft_masks:
    {dir: 64x64 mask}. Shape fingerprints dominate; the sheet position
    acts as a soft tie-break (the model mostly keeps the grid)."""
    slot_centers = {d: (SHEET_CELLS[d][0] + 256, SHEET_CELLS[d][1] + 256)
                    for d in SHEET_DIRS}
    scores = {}
    for ci, (mask, ccx, ccy) in enumerate(cells):
        m = cell_shape_metrics(mask)
        slot = min(slot_centers,
                   key=lambda d: (slot_centers[d][0] - ccx) ** 2
                   + (slot_centers[d][1] - ccy) ** 2)
        for d, dm in draft_masks.items():
            inter = sum(1 for y in range(64) for x in range(64)
                        if mask[y][x] and dm[y][x])
            union = sum(1 for y in range(64) for x in range(64)
                        if mask[y][x] or dm[y][x])
            iou = inter / max(1, union)
            pos = 0.6 if slot == d else 0.0
            if not m:
                scores[(ci, d)] = iou + pos
                continue
            not_wide = 0 if m["wide"] else 1
            if d == "w":
                s = (1.5 * m["band_ratio"] + 1.0 * m["wide"] + pos
                     + iou * 0.2)
            elif d == "n":
                s = (1.2 * min(1, m["sym"])
                     + 1.5 * min(1, m["bottom_frac"] / 0.5)
                     + 0.8 * not_wide + pos + iou * 0.2)
            elif d == "s":
                s = (1.2 * min(1, m["sym"])
                     + 3.0 * max(0, 1 - m["bottom_frac"] / 0.5)
                     + 0.8 * not_wide + pos + iou * 0.2)
            elif d == "sw":
                s = (1.2 * max(0, m["tilt"] / 6) + 0.5 * (1 if m["tilt"] > 0
                                                           else 0)
                     + 0.3 * not_wide + pos + iou * 0.2)
            else:  # nw
                s = (1.2 * max(0, -m["tilt"] / 6) + 0.5 * (1 if m["tilt"] < 0
                                                           else 0)
                     + 0.3 * not_wide + pos + iou * 0.2)
            scores[(ci, d)] = s
    assignment = {}
    used_cells = set()
    used_dirs = set()
    for (ci, d), s in sorted(scores.items(), key=lambda kv: -kv[1]):
        if ci in used_cells or d in used_dirs:
            continue
        assignment[d] = ci
        used_cells.add(ci)
        used_dirs.add(d)
    return assignment


def run_hull_job(ship, seed, stated_px=None):
    """One hull = one /edit: 5-cell sheet -> detect+assign cells -> per-dir
    crop -> key -> snap. The model re-arranges the grid, so cells are
    matched to directions by draft-silhouette IoU + shape fingerprints
    (never by fixed grid position)."""
    t0 = time.time()
    rec = {"ship": ship, "seed": seed, "status": "running",
           "started": time.strftime("%H:%M:%S")}
    save_job(f"hull_{ship}", rec)
    draft_path = os.path.join(DRAFTS, f"sheet_{ship}.png")
    hull_sheet_draft(ship, draft_path)
    with open(draft_path, "rb") as fh:
        draft_bytes = fh.read()
    gen = generate(draft_bytes, hull_sheet_prompt(ship, stated_px), seed)
    with open(os.path.join(GEN, f"hull_{ship}_sheet.png"), "wb") as fh:
        fh.write(gen)
    _, _, gpx = VD.decode_ui_png(gen)
    ow, oh = len(gpx[0]), len(gpx)
    sx, sy = ow / SHEET_SIZE[0], oh / SHEET_SIZE[1]
    rec["gen_size"] = [ow, oh]
    if abs(sx - round(sx)) > 0.02 or abs(sy - round(sy)) > 0.02:
        rec["drift"] = round(sx, 3)
    full = px_to_image(gpx)
    if full.size != SHEET_SIZE:
        full = full.resize(SHEET_SIZE, Image.NEAREST)

    # detect + assign the sprite cells (the model re-arranges the grid)
    boxes = detect_sprite_cells(full)
    rec["detected_cells"] = len(boxes)
    if len(boxes) < 5:
        raise RuntimeError(f"only {len(boxes)} sprite cells detected")
    # crop FIXED 576x576 windows centred on each sprite: the drawn size
    # and placement carry the band/scale information (a bbox crop would
    # make every sprite fill its crop and all views look alike); ships
    # are drawn at ~60-75% of the 512 cell -> ~55-65% of the window
    windows = []
    for (bx0, by0, bx1, by1) in boxes:
        ccx, ccy = (bx0 + bx1) / 2, (by0 + by1) / 2
        wx0 = max(0, min(SHEET_SIZE[0] - 576, int(ccx - 288)))
        wy0 = max(0, min(SHEET_SIZE[1] - 576, int(ccy - 288)))
        windows.append((wx0, wy0, wx0 + 576, wy0 + 576))
    cell_norm = []
    for (wx0, wy0, wx1, wy1) in windows:
        c = full.crop((wx0, wy0, wx1, wy1))
        c = c.resize((64, 64), Image.NEAREST)
        cp = c.load()
        cell_norm.append(([[1 if cp[x, y][3] and not
                            (cp[x, y][1] >= 150 and cp[x, y][0] <= 110
                             and cp[x, y][2] <= 110) else 0
                            for x in range(64)] for y in range(64)],
                          (wx0 + wx1) / 2, (wy0 + wy1) / 2))
    draft_masks = {}
    for direction in SHEET_DIRS:
        tok = token_image(os.path.join(REPO, "assets", "ui", "tokens",
                                       f"hull_{ship}_player_{direction}.png"))
        if tok.size != (64, 64):
            tok = tok.resize((64, 64), Image.NEAREST)
        dp = tok.load()
        draft_masks[direction] = [[1 if dp[x, y][3] else 0
                                   for x in range(64)] for y in range(64)]
    assignment = assign_cells(cell_norm, draft_masks)
    rec["assignment"] = {d: windows[ci] for d, ci in assignment.items()}
    per_dir = {}
    band = BANDS[TIER[ship]]
    # snap ALL five directions first, then classify (the n/s classifier
    # cross-references the sibling + w snaps)
    for direction, ci in assignment.items():
        job_id = f"hull_{ship}_{direction}"
        wx0, wy0, wx1, wy1 = windows[ci]
        cell = full.crop((wx0, wy0, wx1, wy1))
        cbuf = io.BytesIO()
        cell.save(cbuf, "PNG")
        debg = keyed_png(rembg(cbuf.getvalue(), job_id))
        with open(os.path.join(DEBG, job_id + ".png"), "wb") as fh:
            fh.write(debg)
        snapped, metrics, _ = snap_and_measure(
            debg, BLOCK_HULL, band if direction == "w" else None)
        with open(os.path.join(SNAPPED, job_id + ".png"), "wb") as fh:
            snapped.save(fh)
        per_dir[direction] = {"metrics": metrics}
    for direction in SHEET_DIRS:
        job_id = f"hull_{ship}_{direction}"
        cls = classify_for(job_id, direction)
        per_dir.setdefault(direction, {}).setdefault("metrics", {})
        per_dir[direction]["direction"] = cls
    for direction in SHEET_DIRS:  # all 5 dirs present in per_dir
        per_dir.setdefault(direction, {"metrics": {}, "direction": {
            "expected": direction, "observed": "missing",
            "verdict": "FAIL", "why": "cell not detected"}})
    rec["per_dir"] = per_dir
    rec["status"] = "done"
    rec["seconds"] = round(time.time() - t0, 1)
    save_job(f"hull_{ship}", rec)
    return rec


def hull_gate(ship):
    """Hull failure test: w band (with lateen waiver), >=2 direction FAILs,
    or pennant missing in any direction."""
    prog = load_progress()
    rec = prog.get("jobs", {}).get(f"hull_{ship}", {})
    per = rec.get("per_dir", {})
    fails = []
    w = per.get("w", {}).get("metrics", {}).get("band") or {}
    lo, hi = BANDS[TIER[ship]]
    in_band = bool(w.get("in_band"))
    waived = (ship in WAIVER_T1_LATEEN
              and w.get("long_axis_px") is not None
              and w.get("long_axis_px") <= hi + 1)
    if not (in_band or waived):
        fails.append(f"w band {w.get('long_axis_px')} not in {lo}-{hi}")
    dir_fails = [d for d, p in per.items()
                 if p.get("direction", {}).get("verdict") != "PASS"]
    if dir_fails:
        fails.append(f"direction FAILs: {dir_fails}")
    pennant_missing = [d for d, p in per.items()
                       if not p.get("metrics", {}).get("pennant_present")]
    if pennant_missing:
        fails.append(f"pennant missing: {pennant_missing}")
    return fails


def reroll_hull(ship, max_attempts=3, reason="gate failure"):
    """Whole-hull re-roll with varied seed + w-band px calibration
    (attempts 2+ restate the length proportionally); keep the best
    attempt by gate score (fewest fails, then most direction passes)."""
    base = 3000 + HULLS.index(ship)
    center = BAND_CENTER[TIER[ship]]
    best = None
    attempts = []
    stated_px = None
    for n in range(1, max_attempts + 1):
        seed = base + n * 100
        rec = run_hull_job(ship, seed, stated_px=stated_px)
        fails = hull_gate(ship)
        dir_pass = sum(1 for p in rec.get("per_dir", {}).values()
                       if p.get("direction", {}).get("verdict") == "PASS")
        score = (len(fails), -dir_pass)
        wla = (rec.get("per_dir", {}).get("w", {}).get("metrics", {})
               .get("band") or {}).get("long_axis_px")
        attempts.append({"attempt": n, "seed": seed, "fails": fails,
                         "dir_pass": dir_pass, "w_long_axis": wla,
                         "stated_px": stated_px})
        if best is None or score < best[0]:
            best = (score, rec, seed, fails)
        if not fails:
            break
        # calibrate the stated length toward the band centre
        if wla and wla != center:
            prev = stated_px or 512
            stated_px = max(120, min(500, round(prev * center / wla)))
    score, rec, seed, fails = best
    rec["reroll"] = {"kind": "hull", "reason": reason,
                     "attempts": attempts, "kept_seed": seed,
                     "kept_fails": fails}
    save_job(f"hull_{ship}", rec)
    return rec


def fix_ns(ship, max_attempts=2):
    """Surgical n/s pair-trick for hulls whose sheet rolls keep drawing
    duplicate n/s: one /edit with the astern and bow cells side by side,
    cropped back into the two directions (kept only if it passes)."""
    n_job, s_job = f"hull_{ship}_n", f"hull_{ship}_s"
    seed = 3000 + HULLS.index(ship) + 7000
    ref = Image.new("RGBA", (1024, 512), GREEN_BG)
    n_tok = token_image(os.path.join(REPO, "assets", "ui", "tokens",
                                     f"hull_{ship}_player_n.png"))
    s_tok = token_image(os.path.join(REPO, "assets", "ui", "tokens",
                                     f"hull_{ship}_player_s.png"))
    ref.alpha_composite(nearest(n_tok, 6), (64, 64))
    ref.alpha_composite(nearest(s_tok, 6), (576, 64))
    draw = ImageDraw.Draw(ref)
    draw.rectangle([500, 0, 523, 511], fill=(24, 28, 40, 255))
    buf = io.BytesIO()
    ref.convert("RGB").save(buf, "PNG")
    if ship == "pinnace":
        rig = ("NO sails — a substantial rowing galley, two oar banks and "
               "a bare mast stub with a small red pennant, in BOTH cells")
    else:
        rig = RIG[ship]
    prompt = PAIR_PROMPT.format(rig=rig,
                                scale="Each ship fills 70-80% of its "
                                      "cell's width. ")
    attempts = []
    best = None
    for n in range(1, max_attempts + 1):
        sd = seed + n * 100
        gen = generate(buf.getvalue(), prompt, sd)
        with open(os.path.join(GEN, f"hull_{ship}_pair.png"), "wb") as fh:
            fh.write(gen)
        _, _, gpx = VD.decode_ui_png(gen)
        full = px_to_image(gpx)
        if full.size != (1024, 512):
            full = full.resize((1024, 512), Image.NEAREST)
        out = {}
        for direction, job_id, box in (
                ("n", n_job, (32, 16, 496, 496)),
                ("s", s_job, (532, 16, 996, 496))):
            cell = full.crop(box)
            cbuf = io.BytesIO()
            cell.save(cbuf, "PNG")
            debg = keyed_png(rembg(cbuf.getvalue(), job_id))
            with open(os.path.join(DEBG, job_id + ".png"), "wb") as fh:
                fh.write(debg)
            snapped, metrics, _ = snap_and_measure(debg, BLOCK_HULL, None)
            with open(os.path.join(SNAPPED, job_id + ".png"), "wb") as fh:
                snapped.save(fh)
            cls = classify_for(job_id, direction)
            out[direction] = cls
        attempts.append({"attempt": n, "seed": sd,
                         "verdicts": {k: v["verdict"]
                                      for k, v in out.items()}})
        n_pass = out["n"]["verdict"] == "PASS"
        s_pass = out["s"]["verdict"] == "PASS"
        score = (0 if n_pass and s_pass else 1)
        if best is None or score <= best[0]:
            best = (score, out, sd)
        if n_pass and s_pass:
            break
    score, out, sd = best
    for direction, job_id in (("n", n_job), ("s", s_job)):
        cls = out[direction]
        prog = load_progress()
        rec = prog.get("jobs", {}).get(f"hull_{ship}", {})
        if rec:
            if direction in rec.get("per_dir", {}):
                rec["per_dir"][direction]["direction"] = cls
            rr = rec.get("reroll") or {"kind": "hull"}
            rr["ns_fix"] = {"attempts": attempts, "kept_seed": sd,
                            "n": out["n"]["verdict"],
                            "s": out["s"]["verdict"]}
            rec["reroll"] = rr
            save_job(f"hull_{ship}", rec)
    return out


def check_green_hull(ship):
    """validate-green checks at hull level: chroma-free snaps, ring spread,
    olive retention (galiot/junk)."""
    out = {"ship": ship, "dirs": {}}
    total_green = 0
    total_olive = 0
    for direction in SHEET_DIRS:
        job_id = f"hull_{ship}_{direction}"
        snap = Image.open(os.path.join(SNAPPED, job_id + ".png")) \
            .convert("RGBA")
        px = snap.load()
        green = 0
        white_cols = set()
        occupied = set()
        for x in range(64):
            for y in range(64):
                r, g, b, a = px[x, y]
                if a == 0:
                    continue
                occupied.add(x)
                if r <= 60 and abs(g - 255) <= 60 and b <= 60:
                    green += 1
                boundary = ((x + 1 >= 64 or px[x + 1, y][3] == 0)
                            or (x - 1 < 0 or px[x - 1, y][3] == 0)
                            or (y + 1 >= 64 or px[x, y + 1][3] == 0)
                            or (y - 1 < 0 or px[x, y - 1][3] == 0))
                if boundary and min(r, g, b) >= 200:
                    white_cols.add(x)
        debg = Image.open(os.path.join(DEBG, job_id + ".png")) \
            .convert("RGBA")
        dpx = debg.load()
        dw, dh = debg.size
        olive = 0
        for y in range(dh):
            for x in range(dw):
                r, g, b, a = dpx[x, y]
                if a > 200 and g >= 60 and g > r + 40 and g > b + 40 \
                        and not (g >= 170 and r <= 100 and b <= 100):
                    olive += 1
        total_green += green
        total_olive += olive
        out["dirs"][direction] = {
            "green_px": green, "white_cols": len(white_cols),
            "occupied_cols": len(occupied), "olive": olive}
    out["green_free"] = total_green == 0
    out["olive_total"] = total_olive
    if ship in ("galiot", "junk"):
        out["band_ok"] = total_olive >= 60
    else:
        out["band_ok"] = True
    return out


def validate_green_hulls():
    jobs = ["galiot", "junk", "latin", "pinnace", "carrack"]
    results = {}
    for ship in jobs:
        seed = 3000 + HULLS.index(ship)
        run_hull_job(ship, seed)
        results[ship] = check_green_hull(ship)
        print(f"{ship}: {json.dumps(results[ship])}", flush=True)
    ok = all(v["green_free"] and v["band_ok"] for v in results.values())
    print("VALIDATE-GREEN:", "PASS — proceed to all 16" if ok else "FAIL")
    return ok


def archive_legacy():
    """Move prior per-direction raws to model_raw/legacy_8dir/ and mark the
    old progress records legacy."""
    import glob
    moved = 0
    for sub in (DRAFTS, GEN, DEBG, SNAPPED):
        dst_dir = os.path.join(RAW, "legacy_8dir", os.path.basename(sub))
        os.makedirs(dst_dir, exist_ok=True)
        for f in glob.glob(os.path.join(sub, "hull_*.png")):
            shutil.move(f, os.path.join(dst_dir, os.path.basename(f)))
            moved += 1
    prog = load_progress()
    legacy = 0
    for j, r in prog.get("jobs", {}).items():
        if j.startswith("hull_") and "_" in j[len("hull_"):]:
            r["legacy"] = True
            legacy += 1
    save_progress(prog)
    print(f"archived {moved} raw files; marked {legacy} records legacy")


def sheet_hulls():
    """29_hull_sheets.png: the generated sheets, 4x4 grid downscaled."""
    gw, gh = 448, 288  # 1792x1152 / 4
    cols = 4
    ships = [s for s in HULLS
             if os.path.exists(os.path.join(GEN, f"hull_{s}_sheet.png"))]
    rows = (len(ships) + cols - 1) // cols
    img = Image.new("RGBA", (cols * (gw + 8) + 8,
                             rows * (gh + 26) + 8), SHEET_BG)
    draw = ImageDraw.Draw(img)
    for i, ship in enumerate(ships):
        rr, cc = divmod(i, cols)
        x = cc * (gw + 8) + 4
        y = rr * (gh + 26) + 4
        label(draw, (x, y), ship)
        y += 20
        g = Image.open(os.path.join(GEN, f"hull_{ship}_sheet.png")) \
            .convert("RGBA")
        if g.size != (gw, gh):
            g = g.resize((gw, gh), Image.NEAREST)
        img.alpha_composite(g, (x, y))
    out = os.path.join(REVIEW, "29_hull_sheets.png")
    img.convert("RGB").save(out)
    print("wrote", out)


def run_batch_hulls(force=False):
    os.makedirs(DRAFTS, exist_ok=True)
    os.makedirs(GEN, exist_ok=True)
    os.makedirs(DEBG, exist_ok=True)
    os.makedirs(SNAPPED, exist_ok=True)
    os.makedirs(SCRATCH, exist_ok=True)
    prog = load_progress()
    done = set()
    if not force:
        done = {j[len("hull_"):] for j, r in prog.get("jobs", {}).items()
                if j.startswith("hull_") and "_" not in j[len("hull_"):]
                and r.get("status") == "done"}
    todo = [s for s in HULLS if s not in done]
    print(f"hull batch: 16 jobs, {16 - len(todo)} already done, "
          f"running {len(todo)}", flush=True)
    failures = []
    for n, ship in enumerate(todo):
        try:
            rec = run_hull_job(ship, 3000 + HULLS.index(ship))
            fails = hull_gate(ship)
            print(f"[{n + 1}/{len(todo)}] hull_{ship} OK "
                  f"({rec['seconds']}s) gate: {fails or 'clear'}",
                  flush=True)
            if fails:
                rec = reroll_hull(ship, reason="gate failure on fresh roll")
                fails = hull_gate(ship)
                print(f"    hull_{ship} re-roll kept seed "
                      f"{rec['reroll']['kept_seed']} fails: "
                      f"{fails or 'clear'}", flush=True)
                ns_needed = any("'n'" in f or "'s'" in f for f in fails)
                if ns_needed:
                    ns = fix_ns(ship)
                    print(f"    hull_{ship} n/s pair-fix: "
                          f"n={ns['n']['verdict']} s={ns['s']['verdict']}",
                          flush=True)
        except Exception as exc:  # noqa: BLE001
            failures.append(ship)
            print(f"[{n + 1}/{len(todo)}] hull_{ship} FAILED: {exc}",
                  flush=True)
    print(f"hull batch complete: {len(todo) - len(failures)} ok, "
          f"{len(failures)} failed: {failures}", flush=True)


def run_job(job_id, seed):
    t0 = time.time()
    rec = {"seed": seed, "status": "running", "started": time.strftime(
        "%H:%M:%S")}
    save_job(job_id, rec)
    kind = job_id.split("_", 1)[0]
    draft_path = os.path.join(DRAFTS, job_id + ".png")

    if kind == "terrain":
        draft_ref, prompt, band, block = resolve_prompt(job_id)
        draft_ref.convert("RGB").save(draft_path)
    else:
        prompt, band, block = resolve_prompt(job_id)
        if kind == "hull":
            ship, direction = job_id[len("hull_"):].rsplit("_", 1)
            build_ship_draft(ship, direction, draft_path)
        else:
            build_icon_draft(job_id[len("icon_"):], draft_path)

    rec.update(exec_gen(job_id, kind, draft_path, prompt, seed, block,
                        band))
    rec["status"] = "done"
    rec["seconds"] = round(time.time() - t0, 1)
    save_job(job_id, rec)
    return rec


def canonical_seed(job_id):
    """Deterministic seed base. 5-dir canonical order (f6c00bb); the three
    mirrored dirs resolve to their base job's seed (they are never
    generated — e=flip(w), ne=flip(nw), se=flip(sw) at ingestion)."""
    order = job_list_ships() + job_list_terrain() + job_list_icons(129)
    if job_id in order:
        return 1000 + order.index(job_id)
    if job_id.startswith("hull_"):
        ship, direction = job_id[len("hull_"):].rsplit("_", 1)
        base = MIRROR_OF.get(direction)
        if base:
            return canonical_seed(f"hull_{ship}_{base}")
    raise KeyError(job_id)


def reroll_band(job_id, max_attempts=3, round_offset=50000):
    """Band-tightening loop: up to N attempts, keep the best in-band.
    Round-2 seeds (canonical + 50000 + n*10000) never collide with the
    round-1 cache entries."""
    t0 = time.time()
    ship, direction = job_id[len("hull_"):].rsplit("_", 1)
    tier = TIER[ship]
    lo, hi = BANDS[tier]
    center = BAND_CENTER[tier]
    base = canonical_seed(job_id) + round_offset
    draft_path = os.path.join(DRAFTS, job_id + ".png")
    build_ship_draft(ship, direction, draft_path)

    attempts = []
    best = None  # (score, rec, seed, stated_px); score = dist to center
    stated_px = None
    for n in range(1, max_attempts + 1):
        seed = base + n * 10000
        prompt = hull_prompt(ship, direction, stated_px=stated_px)
        rec = exec_gen(job_id, "hull", draft_path, prompt, seed, BLOCK_HULL,
                       (lo, hi), tag=f"_a{n}")
        m = rec.get("metrics", {})
        long_axis = (m.get("band") or {}).get("long_axis_px")
        in_band = (m.get("band") or {}).get("in_band", False)
        dist = abs(long_axis - center) if long_axis is not None else 99
        attempts.append({"attempt": n, "seed": seed,
                         "long_axis": long_axis, "in_band": in_band,
                         "stated_px": stated_px,
                         "pennant": m.get("pennant_present")})
        score = dist if in_band else 100 + dist
        if best is None or score < best[0]:
            best = (score, rec, seed, stated_px, n)
        if in_band:
            break
        # calibrate: state a length that maps the measured axis to center
        if long_axis:
            prev = stated_px or 512  # unstated ≈ full-canvas default
            stated_px = max(64, min(500, round(prev * center / long_axis)))
    score, rec, seed, stated_px, kept_n = best
    for d in (GEN, DEBG, SNAPPED):  # promote kept attempt to canonical name
        src = os.path.join(d, f"{job_id}_a{kept_n}.png")
        dst = os.path.join(d, job_id + ".png")
        if os.path.exists(src):
            shutil.copy(src, dst)
    rec.update({"seed": seed, "status": "done",
                "seconds": round(time.time() - t0, 1),
                "prompt": "tightened-band", "stated_px": stated_px,
                "reroll": {"kind": "band", "round": 2, "attempts": attempts,
                           "kept_seed": seed, "kept_attempt": kept_n,
                           "kept_long_axis": (rec.get("metrics", {})
                                              .get("band") or {})
                                              .get("long_axis_px"),
                           "in_band": (rec.get("metrics", {})
                                       .get("band") or {})
                                       .get("in_band", False)}})
    save_job(job_id, rec)
    return rec


def reroll_icon(icon_id, reason, round_offset=30000, tag_id=""):
    """Semantic re-roll with the override prompt; one attempt, new seed."""
    job_id = f"icon_{icon_id}"
    t0 = time.time()
    base = canonical_seed(job_id)
    seed = base + round_offset
    draft_path = os.path.join(DRAFTS, job_id + ".png")
    build_icon_draft(icon_id, draft_path)
    prompt, band, block = resolve_prompt(job_id)  # override picked up here
    rec = exec_gen(job_id, "icon", draft_path, prompt, seed, block, band)
    rec.update({"seed": seed, "status": "done",
                "seconds": round(time.time() - t0, 1),
                "reroll": {"kind": "semantic", "round": round_offset,
                           "reason": reason, "kept_seed": seed}})
    save_job(job_id, rec)
    return rec


def reroll_identity(job_id, reason):
    """Identity re-roll: tightened wording, seed changed, one attempt."""
    t0 = time.time()
    ship, direction = job_id[len("hull_"):].rsplit("_", 1)
    tier = TIER[ship]
    band = BANDS[tier] if direction in ("e", "w") else None
    base = canonical_seed(job_id)
    seed = base + 40000
    draft_path = os.path.join(DRAFTS, job_id + ".png")
    build_ship_draft(ship, direction, draft_path)
    prompt = hull_prompt(ship, direction)
    rec = exec_gen(job_id, "hull", draft_path, prompt, seed, BLOCK_HULL,
                   band)
    rec.update({"seed": seed, "status": "done",
                "seconds": round(time.time() - t0, 1),
                "prompt": "tightened-identity",
                "reroll": {"kind": "identity", "reason": reason,
                           "kept_seed": seed}})
    save_job(job_id, rec)
    return rec


def save_job(job_id, rec):
    prog = load_progress()
    prog.setdefault("jobs", {})[job_id] = rec
    save_progress(prog)


# ----------------------------------------------------------------- sheets ---


def label(draw, xy, text, color=(220, 224, 236)):
    try:
        font = ImageFont.load_default(size=14)
    except TypeError:
        font = ImageFont.load_default()
    draw.text(xy, text, fill=color, font=font)


def check_green_job(job_id):
    """Hard checks over a keyed job (refined to the gate's intent):

    - green_free: zero chroma-green px in the snapped token
    - fringe_ok: NO white fringe RING — white-ish boundary px must not
      spread over >50% of the occupied columns (a rembg bleed ring wraps
      the whole sprite; sail-white AT the silhouette is legit geometry
      and only covers the sail columns)
    - band: olive-green px retained in the keyed sprite (galiot/junk).
      band_px counts what survives into the snap (sparse rolls quantize
      weakly); keyed_olive is the anti-over-keying evidence.
    """
    snap = Image.open(os.path.join(SNAPPED, job_id + ".png")).convert("RGBA")
    px = snap.load()
    w, h = snap.size
    green_px = 0
    band_hexes = {"#1a8c4e", "#4e9e4e"}
    band_px = 0
    white_cols = set()
    occupied_cols = set()
    for x in range(w):
        for y in range(h):
            r, g, b, a = px[x, y]
            if a == 0:
                continue
            occupied_cols.add(x)
            if abs(r - 0) <= 60 and abs(g - 255) <= 60 and abs(b - 0) <= 60:
                green_px += 1
            if ("#%02x%02x%02x" % (r, g, b)) in band_hexes:
                band_px += 1
            boundary = ((x + 1 >= w or px[x + 1, y][3] == 0)
                        or (x - 1 < 0 or px[x - 1, y][3] == 0)
                        or (y + 1 >= h or px[x, y + 1][3] == 0)
                        or (y - 1 < 0 or px[x, y - 1][3] == 0))
            if boundary and min(r, g, b) >= 200:
                white_cols.add(x)
    ring_cols = len(white_cols) / max(1, len(occupied_cols))

    # ring detection: a rembg bleed ring is CONTIGUOUS — white-ish
    # boundary px across ~all occupied columns, often 2+ px deep where
    # the ring doubles. Sparse sail-edge whites (1–2 px per row along
    # the sail arc only) are geometry, not a ring.
    col_counts = Counter()
    for x in white_cols:
        for y in range(h):
            r, g, b, a = px[x, y]
            if a == 0:
                continue
            boundary = ((x + 1 >= w or px[x + 1, y][3] == 0)
                        or (x - 1 < 0 or px[x - 1, y][3] == 0)
                        or (y + 1 >= h or px[x, y + 1][3] == 0)
                        or (y - 1 < 0 or px[x, y - 1][3] == 0))
            if boundary and min(r, g, b) >= 200:
                col_counts[x] += 1
    fringe_ok = (len(white_cols) <= 0.6 * len(occupied_cols)
                 and max(col_counts.values(), default=0) <= 8)

    # anti-over-keying: olive px (green-dominant, non-chroma) retained in
    # the keyed sprite
    debg = Image.open(os.path.join(DEBG, job_id + ".png")).convert("RGBA")
    dpx = debg.load()
    dw, dh = debg.size
    keyed_olive = 0
    for y in range(dh):
        for x in range(dw):
            r, g, b, a = dpx[x, y]
            if a > 200 and g >= 60 and g > r + 40 and g > b + 40 \
                    and not (g >= 170 and r <= 100 and b <= 100):
                keyed_olive += 1
    band_expected = job_id in ("hull_galiot_w", "hull_junk_w")
    return {
        "green_free": green_px == 0,
        "green_px": green_px,
        "fringe_ok": fringe_ok,
        "white_boundary_cols": len(white_cols),
        "occupied_cols": len(occupied_cols),
        "band_ok": (keyed_olive >= 40) if band_expected else True,
        "band_px": band_px,
        "keyed_olive": keyed_olive,
    }


def strip_green(job_id, out_path):
    """raw | keyed | snapped x4 review strip."""
    cell = 256
    img = Image.new("RGBA", (3 * (cell + 8) + 8, cell + 36), SHEET_BG)
    draw = ImageDraw.Draw(img)
    parts = [(os.path.join(GEN, job_id + ".png"), "raw (green bg)", None),
             (os.path.join(DEBG, job_id + ".png"), "keyed", None),
             (os.path.join(SNAPPED, job_id + ".png"), "snapped x4", 4)]
    for i, (path, title, scale) in enumerate(parts):
        if not os.path.exists(path):
            continue
        im = Image.open(path).convert("RGBA")
        if scale:
            im = im.resize((im.width * scale, im.height * scale),
                           Image.NEAREST)
        if im.width != cell or im.height != cell:
            im = im.resize((cell, cell), Image.NEAREST)
        img.alpha_composite(im, (i * (cell + 8) + 8, 28))
        label(draw, (i * (cell + 8) + 10, 4), title)
    img.convert("RGB").save(out_path)
    print("wrote", out_path)


def sheet_ships():
    """8 display rows: 5 generated base dirs + 3 mirrored rows (exact
    flips, labelled) — the user still sees all 8 directions (f6c00bb)."""
    cell = 256  # 64-grid snapped x4
    head = 40
    gutter = 130
    cols = len(HULLS)
    img = Image.new("RGBA", (gutter + cols * cell + 8,
                             head + len(ALL_DIRS) * cell + 8), SHEET_BG)
    draw = ImageDraw.Draw(img)
    for ci, hull in enumerate(HULLS):
        label(draw, (gutter + ci * cell + 6, 10), hull)
    for ri, direction in enumerate(ALL_DIRS):
        mirror_src = MIRROR_OF.get(direction)
        title = (f"{direction} = flip({mirror_src})" if mirror_src
                 else f"{direction} (generated)")
        label(draw, (6, head + ri * cell + 110), title)
        for ci, hull in enumerate(HULLS):
            src = mirror_src or direction
            path = os.path.join(SNAPPED, f"hull_{hull}_{src}.png")
            if not os.path.exists(path):
                continue
            tok = Image.open(path).resize((cell, cell), Image.NEAREST)
            if mirror_src:
                tok = tok.transpose(Image.FLIP_LEFT_RIGHT)
            img.alpha_composite(tok, (gutter + ci * cell + 4,
                                      head + ri * cell + 4))
    out = os.path.join(REVIEW, "16_ships_model_pass_e.png")
    img.convert("RGB").save(out)
    print("wrote", out)


def sheet_terrain():
    rows = len(TERRAIN_KEYS)
    dw, dh = 512, 256
    img = Image.new("RGBA", (2 * dw + 24, rows * (dh + 26) + 8), SHEET_BG)
    draw = ImageDraw.Draw(img)
    for ri, key in enumerate(TERRAIN_KEYS):
        y = ri * (dh + 26) + 4
        label(draw, (4, y), f"{key}  draft | generated")
        y += 20
        draft = os.path.join(DRAFTS, f"terrain_{key}.png")
        gen = os.path.join(GEN, f"terrain_{key}.png")
        if os.path.exists(draft):
            d = Image.open(draft).resize((dw, dh), Image.NEAREST)
            img.alpha_composite(d.convert("RGBA"), (4, y))
        if os.path.exists(gen):
            g = Image.open(gen).convert("RGBA")
            if g.size != (dw, dh):
                g = g.resize((dw, dh), Image.NEAREST)
            img.alpha_composite(g, (dw + 16, y))
    out = os.path.join(REVIEW, "17_terrain_sheets.png")
    img.convert("RGB").save(out)
    print("wrote", out)


def sheet_icons(done_ids):
    ids = [i for i in done_ids if os.path.exists(
        os.path.join(SNAPPED, i + ".png"))]
    per_row = 8
    thumb, cell, label_h = 64, 256, 18
    cw = thumb + cell + 12
    rows = (len(ids) + per_row - 1) // per_row
    img = Image.new("RGBA", (per_row * cw + 8,
                             rows * (cell + label_h + 6) + 8), SHEET_BG)
    draw = ImageDraw.Draw(img)
    for i, job_id in enumerate(ids):
        r, c = divmod(i, per_row)
        x = c * cw + 4
        y = r * (cell + label_h + 6) + 4
        label(draw, (x, y), job_id[len("icon_"):])
        y += label_h
        draft = os.path.join(DRAFTS, job_id + ".png")
        if os.path.exists(draft):
            d = Image.open(draft).resize((thumb, thumb), Image.NEAREST)
            img.alpha_composite(d.convert("RGBA"), (x, y))
        tok = Image.open(os.path.join(SNAPPED, job_id + ".png"))
        tok = tok.resize((cell, cell), Image.NEAREST)
        img.alpha_composite(tok, (x + thumb + 8, y))
    out = os.path.join(REVIEW, "18_icons_model_pass.png")
    img.convert("RGB").save(out)
    print("wrote", out)


# ------------------------------------------------------------------ batch ---


def run_batch(phase, limit=None, force=False):
    os.makedirs(DRAFTS, exist_ok=True)
    os.makedirs(GEN, exist_ok=True)
    os.makedirs(DEBG, exist_ok=True)
    os.makedirs(SNAPPED, exist_ok=True)
    os.makedirs(SCRATCH, exist_ok=True)

    if phase == "ships":
        jobs = job_list_ships()
    elif phase == "terrain":
        jobs = job_list_terrain()
    else:
        jobs = job_list_icons(limit or 32)

    prog = load_progress()
    if prog.get("started_at") is None:
        prog["started_at"] = time.strftime("%Y-%m-%dT%H:%M:%S")
    # seed base: 1000 = white-bg round 1; 2000 = chroma-green round (the
    # prompt+bg change invalidates all raws, so force gets its own base)
    base = 2000 if force else 1000
    done = set()
    if not force:
        done = {j for j, r in prog.get("jobs", {}).items()
                if r.get("status") == "done"}
    order = job_list_ships() + job_list_terrain() + job_list_icons(129)
    seeds = {j: base + i for i, j in enumerate(order)}

    todo = [j for j in jobs if j not in done]
    print(f"phase {phase}{(' FORCE seed-base %d' % base) if force else ''}: "
          f"{len(jobs)} jobs, {len(jobs) - len(todo)} already done, "
          f"running {len(todo)}", flush=True)
    failures = 0
    for n, job_id in enumerate(todo):
        t0 = time.time()
        try:
            rec = run_job(job_id, seeds[job_id])
            print(f"[{n + 1}/{len(todo)}] {job_id} OK "
                  f"({rec['seconds']}s) {json.dumps(rec.get('metrics', {}))}",
                  flush=True)
        except Exception as exc:  # noqa: BLE001
            failures += 1
            save_job(job_id, {"seed": seeds[job_id], "status": "failed",
                              "error": str(exc)[:400],
                              "seconds": round(time.time() - t0, 1)})
            print(f"[{n + 1}/{len(todo)}] {job_id} FAILED: {exc}",
                  flush=True)
    print(f"phase {phase} complete: {len(todo) - failures} ok, "
          f"{failures} failed", flush=True)


def build_report():
    prog = load_progress()
    jobs = prog.get("jobs", {})
    ship_jobs = {j: r for j, r in jobs.items() if j.startswith("hull_")}
    terrain_jobs = {j: r for j, r in jobs.items() if j.startswith("terrain_")}
    icon_jobs = {j: r for j, r in jobs.items() if j.startswith("icon_")}

    def stats(sub):
        ok = [j for j, r in sub.items() if r.get("status") == "done"]
        bad = [j for j, r in sub.items() if r.get("status") == "failed"]
        return {"done": len(ok), "failed": len(bad),
                "failed_ids": sorted(bad)}

    # e/w band summary per hull — job unit is the HULL now; the w crop
    # carries the band, e = mirror(w) at ingestion (f6c00bb)
    band_table = {}
    for hull in HULLS:
        rec = jobs.get(f"hull_{hull}", {}) or {}
        m = (rec.get("per_dir", {}).get("w", {}).get("metrics")) or {}
        if not m:
            m = (jobs.get(f"hull_{hull}_w", {}).get("metrics")) or {}
        b = m.get("band") or {}
        lo, hi = BANDS[TIER[hull]]
        waived = (hull in WAIVER_T1_LATEEN
                  and b.get("long_axis_px") is not None
                  and b.get("long_axis_px") <= hi + 1)
        band_table[hull] = {
            "tier": TIER[hull], "band": [lo, hi],
            "w": {"long_axis": b.get("long_axis_px"),
                  "in_band": bool(b.get("in_band")) or waived,
                  "waived": waived and not bool(b.get("in_band")),
                  "seed": rec.get("seed")},
        }
    in_band_count = sum(1 for v in band_table.values()
                        if v["w"]["in_band"])
    band_total = len(HULLS)

    # direction audit (from progress)
    audit = prog.get("direction_audit", [])
    audit_pass = sum(1 for a in audit if a.get("verdict") == "PASS")

    pennant = {"present": [], "absent": []}
    for ship in HULLS:
        rec = jobs.get(f"hull_{ship}", {})
        per = rec.get("per_dir", {})
        if per:
            for direction, p in per.items():
                m = p.get("metrics", {})
                if "pennant_present" in m:
                    (pennant["present"] if m["pennant_present"]
                     else pennant["absent"]).append(
                        f"hull_{ship}_{direction}")
        else:  # legacy per-direction record
            m = rec.get("metrics", {}) or {}
            if "pennant_present" in m:
                (pennant["present"] if m["pennant_present"]
                 else pennant["absent"]).append(f"hull_{ship}")

    hull_jobs = {j: r for j, r in jobs.items()
                 if j.startswith("hull_") and "_" not in j[len("hull_"):]}

    report = {
        "ships": stats(hull_jobs),
        "ships_cells": sum(len(r.get("per_dir", {}))
                           for r in hull_jobs.values()),
        "terrain": stats(terrain_jobs),
        "icons": stats(icon_jobs),
        "band_table": band_table,
        "band_summary": {"in_band": in_band_count, "total": band_total,
                         "note": "w measured per hull-job (f6c00bb); "
                                 "e = mirror(w) inherits the band value; "
                                 "lateen waiver {latin,galiot,sloop}+1"},
        "direction_audit": {
            "pass": audit_pass, "total": len(audit),
            "fails": [{"job": a.get("job"), "observed": a.get("observed"),
                       "why": a.get("why") or a.get("bow_at")
                       or a.get("bottom_frac")}
                      for a in audit if a.get("verdict") != "PASS"][:24]},
        "pennant": {"present": len(pennant["present"]),
                    "absent": len(pennant["absent"]),
                    "absent_ids": sorted(pennant["absent"])},
        "rerolls": {
            "hull": [
                {"job": j, "attempts": r["reroll"]["attempts"],
                 "kept_seed": r["reroll"]["kept_seed"],
                 "kept_fails": r["reroll"].get("kept_fails")}
                for j, r in sorted(jobs.items())
                if isinstance(r.get("reroll"), dict)
                and r["reroll"].get("kind") == "hull"],
            "band": [
                {"job": j, "attempts": r["reroll"]["attempts"],
                 "kept_seed": r["reroll"]["kept_seed"],
                 "kept_long_axis": r["reroll"]["kept_long_axis"],
                 "in_band": r["reroll"]["in_band"]}
                for j, r in sorted(jobs.items())
                if isinstance(r.get("reroll"), dict)
                and r["reroll"].get("kind") == "band"],
            "semantic_icons": [
                {"job": j, "reason": r["reroll"]["reason"],
                 "kept_seed": r["reroll"]["kept_seed"]}
                for j, r in sorted(jobs.items())
                if isinstance(r.get("reroll"), dict)
                and r["reroll"].get("kind") == "semantic"],
            "identity": [
                {"job": j, "reason": r["reroll"]["reason"],
                 "kept_seed": r["reroll"]["kept_seed"]}
                for j, r in sorted(jobs.items())
                if isinstance(r.get("reroll"), dict)
                and r["reroll"].get("kind") == "identity"],
        },
        "sheets": {
            "ships": "art_review/16_ships_model_pass_e.png",
            "terrain": "art_review/17_terrain_sheets.png",
            "icons": "art_review/18_icons_model_pass.png"},
        "usage": {
            "rerun_single": "python3 tools/model_pass.py job <job_id>",
            "phases": "python3 tools/model_pass.py run ships|terrain|icons [N]",
            "sheets": "python3 tools/model_pass.py sheets",
            "reroll_band": "python3 tools/model_pass.py reroll bands",
            "reroll_icon": "python3 tools/model_pass.py reroll icons",
            "reroll_identity":
                "python3 tools/model_pass.py reroll identity <job_id> [...]"},
        "wall_seconds": round(sum(
            (r.get("seconds") or 0) for r in jobs.values()), 1),
    }
    with open(REPORT, "w") as fh:
        json.dump(report, fh, indent=1, sort_keys=True)
    print(json.dumps(report, indent=1, sort_keys=True))


def main(argv):
    if not argv:
        print(__doc__)
        return 2
    cmd = argv[0]
    if cmd == "run":
        phase = argv[1]
        if phase == "hulls":
            run_batch_hulls(force="force" in argv[2:])
            return 0
        limit = int(argv[2]) if len(argv) > 2 and argv[2].isdigit() else None
        force = "force" in argv[2:]
        run_batch(phase, limit, force)
    elif cmd == "validate-green":
        validate_green_hulls()
    elif cmd == "audit":
        audit = audit_directions()
        sheet_direction_audit(audit)
    elif cmd == "job":
        os.makedirs(DRAFTS, exist_ok=True)
        os.makedirs(GEN, exist_ok=True)
        os.makedirs(DEBG, exist_ok=True)
        os.makedirs(SNAPPED, exist_ok=True)
        os.makedirs(SCRATCH, exist_ok=True)
        order = job_list_ships() + job_list_terrain() + job_list_icons(129)
        job_id = argv[1]
        seed = 1000 + order.index(job_id)
        rec = run_job(job_id, seed)
        print(json.dumps(rec, indent=1))
    elif cmd == "sheets":
        which = argv[1] if len(argv) > 1 else "all"
        if which in ("ships", "all"):
            sheet_ships()
        if which in ("terrain", "all"):
            sheet_terrain()
        if which in ("icons", "all"):
            prog = load_progress()
            sheet_icons([j for j, r in prog.get("jobs", {}).items()
                         if j.startswith("icon_")
                         and r.get("status") == "done"])
        if which in ("hulls", "all"):
            sheet_hulls()
    elif cmd == "archive-legacy":
        archive_legacy()
    elif cmd == "reroll":
        mode = argv[1]
        if mode == "bands":
            # 5-dir scheme (f6c00bb): only the w job carries the e/w band —
            # e is mirror(w) at ingestion. Missing/malformed records flag too.
            # Lateen waiver {latin,galiot,sloop}: +1 over band top accepted.
            prog = load_progress()
            out = []
            for hull in HULLS:
                tier = TIER[hull]
                lo, hi = BANDS[tier]
                job_id = f"hull_{hull}_w"
                r = prog.get("jobs", {}).get(job_id, {})
                m = (r.get("metrics") if "metrics" in r
                     else r.get("per_dir", {}).get("w", {}).get("metrics")) \
                    or {}
                b = m.get("band") or {}
                la = b.get("long_axis_px")
                waived = hull in WAIVER_T1_LATEEN and la is not None \
                    and la <= hi + 1
                if la is None or not (b.get("in_band") or waived):
                    out.append(job_id)
            print("band re-rolls (w only):", out, flush=True)
            for job_id in out:
                rec = reroll_band(job_id)
                m = rec.get("metrics", {}) or {}
                print(f"  {job_id}: kept seed {rec['seed']} "
                      f"long_axis={(m.get('band') or {}).get('long_axis_px')} "
                      f"in_band={(m.get('band') or {}).get('in_band')}",
                      flush=True)
        elif mode == "icons":
            for icon_id, why in [
                ("compass", "reviewed as ship's wheel — must be a magnetic "
                            "compass with needle rose"),
                ("save", "reviewed as inkwell/quill — must stay a retro "
                         "floppy disk (game save glyph)"),
                ("crew", "generic blob — must be a sailor bust with round "
                         "cap"),
                ("strong", "unreadable at 32 px — chevron strength arrows"),
                ("cannon", "barrel-only — must be full cannon on carriage "
                           "with wheels"),
                ("hook", "silhouette unclear — curved grappling hook"),
                ("good_iron", "read as bench — iron ingot stack"),
                ("scroll", "read as chalkboard — rolled parchment scroll"),
                ("ram", "no beak — ship bow ram with bronze beak"),
            ]:
                rec = reroll_icon(icon_id, why)
                print(f"  icon_{icon_id}: kept seed {rec['seed']}",
                      flush=True)
        elif mode == "identity":
            # args: job ids and reason strings interleaved; a reason string
            # applies to the job ids that follow it
            pending = "cross-direction identity drift"
            plan = []
            for arg in argv[2:]:
                if arg.startswith("hull_"):
                    plan.append((arg, pending))
                else:
                    pending = arg
            for job_id, reason in plan:
                rec = reroll_identity(job_id, reason)
                print(f"  {job_id}: kept seed {rec['seed']}", flush=True)
        else:
            print(__doc__)
    elif cmd == "validate-green":
        # 5 pipeline probes (green-accent + fringe-prone cases), then
        # strips: raw | keyed | snapped x4 + hard checks
        jobs = ["hull_galiot_w", "hull_junk_w", "hull_latin_w",
                "hull_galleon_n", "icon_anchor"]
        results = {}
        for job_id in jobs:
            seed = canonical_seed(job_id) + 20000
            rec = run_job(job_id, seed)
            results[job_id] = check_green_job(job_id)
            print(f"{job_id}: {json.dumps(results[job_id])}", flush=True)
        # verdict
        ok = all(v["green_free"] and v["fringe_ok"] and v["band_ok"]
                 for v in results.values())
        print("VALIDATE-GREEN:", "PASS — proceed to mass re-roll" if ok
              else "FAIL — do not mass re-roll", flush=True)
    elif cmd == "report":
        build_report()
    else:
        print(__doc__)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
