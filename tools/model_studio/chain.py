#!/usr/bin/env python3
"""SailAge model-studio generation chain — the validated model-pass pipeline,
self-contained (tools/model_pass.py is NOT imported, only parsed read-only
for canonical prompt wording).

Pipeline per sprite job:
  1. draft  : <repo>/tools/ui_art/model_raw/drafts/<job>.png (MAIN repo,
              read-only) -> base64 -> POST http://127.0.0.1:8001/edit
              {"image","prompt","seed"}; the response body IS the PNG
              (2 attempts).
  2. rembg  : ComfyUI http://127.0.0.1:8000 — multipart /upload/image, the
              API-format workflow from the LifeSimulator template AS-IS
              (InvertMask kept — polarity verified), /prompt, poll
              /history, fetch /view.
  3. snap   : nearest-resize to 512x512 -> majority-vote downscale to the
              64 logical grid over opaque px -> quantize to
              sorted(validate_data.BLOCK_HULL) (BLOCK_ICON for icons) ->
              hull-only pennant-source snap (channel-sum delta <= 40 of
              #b3191f -> the exact source hex) + masthead presence check
              + e/w long-axis band check (bands 28-36 / 40-52 / 52-60).
  4. writes : studio cache ONLY — model_raw/studio/{gen,snapped,debg}/<job>.png
              (debg is the rembg intermediate, kept so an offline re-check
              can re-run the snap deterministically). Atomic (tmp+replace).
              Canonical gen//snapped/ are never written.

Terrain jobs skip rembg/snap (the validated driver's terrain path): the gen
response is decoded, nearest-normalized to 1024x512 when it drifts, and
stored as the studio gen artifact.

Canonical prompts are reconstructed by PARSING the driver file read-only:
literal constants via ast.literal_eval, ICON_PROMPT_OVERRIDES (which
references ICON_STYLE by name) via an AST-validated eval against the
already-parsed ICON_STYLE. The terrain texture clauses are embedded verbatim
(they are function-local in the driver and cannot be parsed as literals).

PNG decode: tools/validate_data.decode_ui_png (imported from the MAIN repo
by absolute path; indexed type-3 + RGBA type-6) with a local truecolor
fallback for type-2 RGB payloads. PNG encode: local minimal zlib writer
(8-bit RGBA, filter 0). stdlib only.
"""

from __future__ import annotations

import ast
import base64
import json
import os
import random
import re
import struct
import sys
import time
import urllib.request
import uuid
import zlib
from collections import Counter

# --------------------------------------------------------------- services --

EDIT_URL = "http://127.0.0.1:8001/edit"
COMFY = "http://127.0.0.1:8000"
REMBG_WF = ("/home/weidong/repo/LifeSimulator/src/lib/comfyui/"
            "workflow-template-rembg.json")
CLIENT_ID = "sailage-studio"

PENNANT_SOURCE = "#b3191f"      # the authored masthead source hex (§4.8.4)
PENNANT_SNAP_MAX = 40           # channel-sum |Δ| that snaps to the source
BANDS = {1: (28, 36), 2: (40, 52), 3: (52, 60)}  # 64-grid tier bands (e/w)
JOB_RE = re.compile(r"^[a-z0-9_]+$")

# ------------------------------------------------------------- repo paths --

REPO = None
RAW = None
STUDIO = None
_DRAFTS = None
_VD = None  # validate_data module (loaded by init() from the MAIN repo)


def init(repo: str) -> None:
    """Point the chain at the MAIN repo (read-only inputs) and create the
    studio cache dirs. Call once at server boot."""
    global REPO, RAW, STUDIO, _DRAFTS, _VD
    REPO = repo
    RAW = os.path.join(repo, "tools", "ui_art", "model_raw")
    STUDIO = os.path.join(RAW, "studio")
    _DRAFTS = os.path.join(RAW, "drafts")
    for sub in ("gen", "snapped", "debg"):
        os.makedirs(os.path.join(STUDIO, sub), exist_ok=True)
    import types  # noqa: PLC0415 — stdlib
    tools_dir = os.path.join(repo, "tools")
    if tools_dir not in sys.path:
        sys.path.insert(0, tools_dir)
    # The studio needs only decode_ui_png + the BLOCK_* palettes from
    # validate_data — but its module-level import chain grows with the repo
    # (build_routes -> build_world -> vendored pyshp). Stub any sibling that
    # fails to import (bounded retries); validate_data only CALLS those
    # builders from its own main(), never at import time.
    global validate_data
    for _attempt in range(8):
        try:
            import validate_data as _vd_mod  # noqa: PLC0415
            validate_data = _vd_mod
            _VD = _vd_mod
            break
        except ModuleNotFoundError as exc:
            name = exc.name or ""
            if not name or name in sys.modules:
                raise
            print(f"[studio-chain] stubbing unavailable module {name!r} "
                  f"for validate_data import", flush=True)
            sys.modules[name] = types.ModuleType(name)
    else:
        raise RuntimeError("validate_data import kept failing")
    _VD = validate_data


def studio_path(kind: str, job_id: str) -> str:
    return os.path.join(STUDIO, kind, job_id + ".png")


def canonical_path(kind: str, job_id: str) -> str:
    return os.path.join(RAW, kind, job_id + ".png")


# ------------------------------------------------------------------ png io --

_PNG_SIG = b"\x89PNG\r\n\x1a\n"


def decode_rgba(data: bytes) -> tuple[int, int, list[list]]:
    """Decode a PNG into (w, h, rows-of-hex-or-None). Indexed type-3 and
    RGBA type-6 go through the main repo's validated reader; truecolor
    type-2 falls back to the local reader below."""
    if not data.startswith(_PNG_SIG):
        raise ValueError("not a PNG")
    w, h, depth, colour = struct.unpack(">IIBB", data[16:26])
    if depth != 8:
        raise ValueError(f"unsupported bit depth {depth}")
    if colour in (3, 6):
        return _VD.decode_ui_png(data)
    if colour == 2:
        return _decode_truecolor(data)
    raise ValueError(f"unsupported colour type {colour}")


def _decode_truecolor(data: bytes) -> tuple[int, int, list[list]]:
    """Minimal reader for 8-bit non-interlaced RGB (type 2) PNGs."""
    pos = 8
    idat = bytearray()
    palette = None
    width = height = 0
    while pos < len(data):
        (length, ) = struct.unpack(">I", data[pos:pos + 4])
        tag = data[pos + 4:pos + 8]
        payload = data[pos + 8:pos + 8 + length]
        if tag == b"IHDR":
            width, height, depth, colour, _c, _f, _i = struct.unpack(
                ">IIBBBBB", payload)
            if depth != 8 or colour != 2:
                raise ValueError("truecolor reader needs 8-bit RGB")
        elif tag == b"PLTE":
            palette = payload
        elif tag == b"IDAT":
            idat += payload
        elif tag == b"IEND":
            break
        pos += 12 + length
    stride = width * 3
    raw = zlib.decompress(bytes(idat))
    lines = []
    prev = bytes(stride)
    pos = 0
    for _ in range(height):
        ftype = raw[pos]
        pos += 1
        line = bytearray(raw[pos:pos + stride])
        pos += stride
        if ftype == 1:  # Sub
            for i in range(3, stride):
                line[i] = (line[i] + line[i - 3]) & 0xFF
        elif ftype == 2:  # Up
            for i in range(stride):
                line[i] = (line[i] + prev[i]) & 0xFF
        elif ftype == 3:  # Average
            for i in range(stride):
                left = line[i - 3] if i >= 3 else 0
                line[i] = (line[i] + ((left + prev[i]) >> 1)) & 0xFF
        elif ftype == 4:  # Paeth
            for i in range(stride):
                a = line[i - 3] if i >= 3 else 0
                b = prev[i]
                c = prev[i - 3] if i >= 3 else 0
                p = a + b - c
                pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                pred = a if (pa <= pb and pa <= pc) else (
                    b if pb <= pc else c)
                line[i] = (line[i] + pred) & 0xFF
        elif ftype != 0:
            raise ValueError(f"undefined PNG filter {ftype}")
        lines.append(bytes(line))
        prev = line
    px = []
    for line in lines:
        row = []
        for x in range(width):
            r, g, b = line[x * 3:x * 3 + 3]
            row.append("#%02x%02x%02x" % (r, g, b))
        px.append(row)
    return width, height, px


def encode_png(w: int, h: int, rows: list[list]) -> bytes:
    """Encode hex-or-None rows as an 8-bit RGBA PNG (filter 0 rows)."""
    raw = bytearray()
    for row in rows:
        raw.append(0)
        for c in row:
            if c is None:
                raw += b"\x00\x00\x00\x00"
            else:
                raw += bytes((int(c[1:3], 16), int(c[3:5], 16),
                              int(c[5:7], 16), 255))
    comp = zlib.compress(bytes(raw), 6)

    def chunk(tag: bytes, payload: bytes) -> bytes:
        return (struct.pack(">I", len(payload)) + tag + payload
                + struct.pack(">I", zlib.crc32(tag + payload) & 0xFFFFFFFF))

    ihdr = struct.pack(">IIBBBBB", w, h, 8, 6, 0, 0, 0)
    return (_PNG_SIG + chunk(b"IHDR", ihdr) + chunk(b"IDAT", comp)
            + chunk(b"IEND", b""))


def atomic_write(path: str, data: bytes) -> None:
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "wb") as fh:
        fh.write(data)
        fh.flush()
        os.fsync(fh.fileno())
    os.replace(tmp, path)


def _resize_nearest(rows, w, h, nw, nh):
    """PIL-NEAREST-equivalent centre mapping on hex-or-None rows."""
    sx = [min(w - 1, int((i + 0.5) * w / nw)) for i in range(nw)]
    sy = [min(h - 1, int((j + 0.5) * h / nh)) for j in range(nh)]
    return [[rows[sy[j]][sx[i]] for i in range(nw)] for j in range(nh)]


# ------------------------------------------------------------- model calls --


def _http_json(url: str, payload: dict, timeout: int) -> bytes:
    req = urllib.request.Request(
        url, data=json.dumps(payload).encode("utf-8"),
        headers={"Content-Type": "application/json"}, method="POST")
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return resp.read()


def _check_png(body: bytes, what: str) -> bytes:
    if body[:8] != _PNG_SIG:
        raise RuntimeError(f"{what} returned a non-PNG "
                           f"(len={len(body)}, head={body[:24]!r})")
    return body


def generate(draft_bytes: bytes, prompt: str, seed: int) -> bytes:
    """POST :8001/edit; the response body IS the PNG. One retry, then raise."""
    payload = {"image": base64.b64encode(draft_bytes).decode("ascii"),
               "prompt": prompt, "seed": int(seed)}
    last = None
    for attempt in (1, 2):
        try:
            body = _http_json(EDIT_URL, payload, timeout=180)
            return _check_png(body, "generate")
        except Exception as exc:  # noqa: BLE001 — one retry, then raise
            last = exc
            print(f"[studio-chain] generate attempt {attempt} failed: {exc}",
                  flush=True)
            time.sleep(2)
    raise RuntimeError(f"generate failed twice: {last}")


def _multipart(fields: dict, fname: str, content: bytes) -> tuple[bytes, str]:
    boundary = uuid.uuid4().hex
    parts = []
    for key, val in fields.items():
        parts.append(f"--{boundary}\r\nContent-Disposition: form-data; "
                     f'name="{key}"\r\n\r\n{val}\r\n')
    head = "".join(parts).encode("utf-8") + (
        f"--{boundary}\r\nContent-Disposition: form-data; "
        f'name="image"; filename="{fname}"\r\n'
        f"Content-Type: image/png\r\n\r\n").encode("utf-8")
    body = head + content + f"\r\n--{boundary}--\r\n".encode("utf-8")
    return body, boundary


def rembg(gen_bytes: bytes, job_id: str) -> bytes:
    """ComfyUI rembg — the LifeSimulator workflow template AS-IS
    (InvertMask kept; polarity verified). Upload -> /prompt -> poll
    /history -> /view."""
    with open(REMBG_WF, "r", encoding="utf-8") as fh:
        wf = json.load(fh)
    fname = f"{job_id}_{uuid.uuid4().hex[:8]}.png"
    body, boundary = _multipart(
        {"overwrite": "true", "type": "input", "subfolder": ""},
        fname, gen_bytes)
    req = urllib.request.Request(
        f"{COMFY}/upload/image", data=body,
        headers={"Content-Type": f"multipart/form-data; boundary={boundary}"},
        method="POST")
    with urllib.request.urlopen(req, timeout=60) as resp:
        up = json.loads(resp.read())
    uploaded = up["name"]
    wf["1"]["inputs"]["image"] = uploaded
    wf["6"]["inputs"]["filename_prefix"] = f"studio_{job_id}"
    body = json.dumps({"prompt": wf, "client_id": CLIENT_ID}).encode("utf-8")
    req = urllib.request.Request(
        f"{COMFY}/prompt", data=body,
        headers={"Content-Type": "application/json"}, method="POST")
    with urllib.request.urlopen(req, timeout=60) as resp:
        prompt_id = json.loads(resp.read())["prompt_id"]
    for _ in range(120):
        time.sleep(1)
        with urllib.request.urlopen(f"{COMFY}/history/{prompt_id}",
                                    timeout=30) as resp:
            hist = json.loads(resp.read())
        if prompt_id in hist:
            imgs = hist[prompt_id].get("outputs", {}).get("6", {}).get("images")
            if imgs:
                im = imgs[0]
                url = (f"{COMFY}/view?filename={urllib.request.quote(im['filename'])}"
                       f"&subfolder={urllib.request.quote(im['subfolder'])}"
                       f"&type={urllib.request.quote(im['type'])}")
                with urllib.request.urlopen(url, timeout=60) as resp:
                    return _check_png(resp.read(), "rembg /view")
            raise RuntimeError("rembg history has no output images: "
                               f"{hist[prompt_id].get('status')}")
    raise RuntimeError("rembg timed out after 120 s")


# ------------------------------------------------------------------ snapping --


def _hex_rgb(c: str) -> tuple[int, int, int]:
    return (int(c[1:3], 16), int(c[3:5], 16), int(c[5:7], 16))


def _hex_dist2(a: str, b: str) -> int:
    ar, ag, ab = _hex_rgb(a)
    br, bg, bb = _hex_rgb(b)
    return (ar - br) ** 2 + (ag - bg) ** 2 + (ab - bb) ** 2


def _chan_sum_dist(a: str, b: str) -> int:
    ar, ag, ab = _hex_rgb(a)
    br, bg, bb = _hex_rgb(b)
    return abs(ar - br) + abs(ag - bg) + abs(ab - bb)


def _quantize(hexcolor: str, block) -> str:
    best, best_d = None, None
    for cand in block:  # sorted palette; first-lowest wins ties
        d = _hex_dist2(hexcolor, cand)
        if best_d is None or d < best_d:
            best, best_d = cand, d
    return best


def snap(debg_bytes: bytes, block, band=None, pennant_snap=False):
    """512-grid majority vote -> 64 logical grid, quantized (+ optional
    pennant-source snap) with the validated metrics. Returns (rows64,
    metrics) exactly like the driver's snap_and_measure."""
    w, h, px = decode_rgba(debg_bytes)
    if (w, h) != (512, 512):
        px = _resize_nearest(px, w, h, 512, 512)
    rgb_cache: dict[str, tuple[int, int, int]] = {}

    def rgb(c: str):
        got = rgb_cache.get(c)
        if got is None:
            got = rgb_cache[c] = _hex_rgb(c)
        return got

    grid = []
    opaque_cells = 0
    for gy in range(64):
        row = []
        for gx in range(64):
            cnt = Counter()
            for y in range(gy * 8, gy * 8 + 8):
                prow = px[y]
                for x in range(gx * 8, gx * 8 + 8):
                    c = prow[x]
                    if c is not None:
                        cnt[rgb(c)] += 1
            if not cnt:
                row.append(None)
            else:
                opaque_cells += 1
                winner = max(cnt.items(), key=lambda kv: (kv[1], kv[0]))[0]
                q = _quantize("#%02x%02x%02x" % winner, block)
                if pennant_snap and _chan_sum_dist(q, PENNANT_SOURCE) <= \
                        PENNANT_SNAP_MAX:
                    q = PENNANT_SOURCE
                row.append(q)
        grid.append(row)

    xs = [x for y in range(64) for x in range(64) if grid[y][x]]
    ys = [y for y in range(64) for x in range(64) if grid[y][x]]
    bbox = (min(xs), min(ys), max(xs), max(ys)) if xs else None
    metrics = {
        "opaque_pct": round(100.0 * opaque_cells / (64 * 64), 1),
        "bbox": list(bbox) if bbox else None,
        "fit_inside_64": bool(bbox and bbox[0] >= 0 and bbox[1] >= 0
                              and bbox[2] < 64 and bbox[3] < 64),
    }
    if band and bbox:
        lo, hi = band
        width = bbox[2] - bbox[0] + 1
        metrics["band"] = {"long_axis_px": width, "band": list(band),
                           "in_band": lo <= width <= hi}

    red_hexes = ("#b3191f", "#b3341f")
    count = 0
    for y in range(64):
        for x in range(64):
            c = grid[y][x]
            if c is None:
                continue
            if any(_hex_dist2(c, rh) <= 90 * 90 for rh in red_hexes):
                if bbox and y <= bbox[1] + (bbox[3] - bbox[1]) * 0.45:
                    count += 1
    metrics["pennant_red_px"] = count
    metrics["pennant_present"] = count >= 3
    return grid, metrics


def key_green_rows(w: int, h: int, rows: list[list], thr: int = 60):
    """The driver's key_green post-pass, on hex|None rows (binary alpha:
    None = transparent). Faithful sequence: corner-median reference chroma,
    border-connected green flood, connectivity-free bright-green kill,
    despill (G -> max(R, B)) on edge px, 1px alpha erosion."""
    alpha = [0 if c is None else 255 for row in rows for c in row]

    def rgb(i):
        c = rows[i // w][i % w]
        return (0, 0, 0) if c is None else _hex_rgb(c)

    # reference chroma from the four corner patches (median per channel)
    rs, gs, bs = [], [], []
    for cx, cy in ((0, 0), (w - 40, 0), (0, h - 40), (w - 40, h - 40)):
        for y in range(max(0, cy), min(h, cy + 40)):
            base = y * w
            for x in range(max(0, cx), min(w, cx + 40)):
                r, g, b = rgb(base + x)
                rs.append(r); gs.append(g); bs.append(b)
    rs.sort(); gs.sort(); bs.sort()
    ref = (rs[len(rs) // 2], gs[len(gs) // 2], bs[len(bs) // 2])

    def greenish(i):
        r, g, b = rgb(i)
        if g < 90:
            return False
        strict = (abs(r - ref[0]) <= thr and abs(g - ref[1]) <= thr
                  and abs(b - ref[2]) <= thr)
        dominant = g > r + 40 and g > b + 40
        return strict or dominant

    # border-connected flood fill over green-ish px
    from collections import deque
    flood = bytearray(w * h)
    stack = deque()
    for x in range(w):
        for y in (0, h - 1):
            i = y * w + x
            if not flood[i] and greenish(i):
                flood[i] = 1
                stack.append(i)
    for y in range(h):
        for x in (0, w - 1):
            i = y * w + x
            if not flood[i] and greenish(i):
                flood[i] = 1
                stack.append(i)
    while stack:
        i = stack.popleft()
        x, y = i % w, i // w
        for nx, ny in ((x + 1, y), (x - 1, y), (x, y + 1), (x, y - 1)):
            if 0 <= nx < w and 0 <= ny < h:
                j = ny * w + nx
                if not flood[j] and greenish(j):
                    flood[j] = 1
                    stack.append(j)
    for i in range(w * h):
        if flood[i]:
            alpha[i] = 0
    # connectivity-free bright-green kill (enclosed chroma pockets)
    for i in range(w * h):
        if alpha[i]:
            r, g, b = rgb(i)
            if g >= 170 and r <= 100 and b <= 100:
                alpha[i] = 0
    # despill: surviving edge px lose the green cast
    for y in range(h):
        for x in range(w):
            i = y * w + x
            if not alpha[i]:
                continue
            r, g, b = rgb(i)
            if g <= max(r, b):
                continue
            edge = (y == 0 or y == h - 1 or x == 0 or x == w - 1
                    or alpha[y * w + (x + 1 if x + 1 < w else x)] == 0
                    or alpha[y * w + (x - 1 if x else x)] == 0
                    or alpha[(y + 1 if y + 1 < h else y) * w + x] == 0
                    or alpha[(y - 1 if y else y) * w + x] == 0)
            if edge:
                rows[y][x] = "#%02x%02x%02x" % (r, max(r, b), b)
    # 1px alpha erosion: any 4-neighbour transparent -> transparent
    snap_alpha = list(alpha)
    for y in range(h):
        for x in range(w):
            i = y * w + x
            if not snap_alpha[i]:
                continue
            for nx, ny in ((x + 1, y), (x - 1, y), (x, y + 1), (x, y - 1)):
                if not (0 <= nx < w and 0 <= ny < h) \
                        or snap_alpha[ny * w + nx] < 32:
                    alpha[i] = 0
                    break
    return [[None if alpha[y * w + x] == 0 else rows[y][x]
             for x in range(w)] for y in range(h)]


def key_green_bytes(png_bytes: bytes) -> bytes:
    w, h, rows = decode_rgba(png_bytes)
    return encode_png(w, h, key_green_rows(w, h, rows))


def crop_rows(rows, x0, y0, x1, y1):
    """Rectangle crop of hex|None rows (exclusive x1/y1)."""
    return [row[x0:x1] for row in rows[y0:y1]]


# ------------------------------------------------------------- driver parse ---

_LITERAL_NAMES = ("HULLS", "DIRS", "TIER", "BANDS", "POSE", "RIG", "COMPACT",
                  "STYLE", "ICON_STYLE", "ICON_PRIORITY", "TERRAIN_KEYS")
_DRIVER: dict | None = None

# Hard fallback: the master's proven wording, embedded verbatim from
# tools/model_pass.py (f6c00bb era). Used when the driver file cannot be
# parsed (torn read while the re-roll round rewrites it) or drifts shape —
# prompt boxes must NEVER go empty and /api/jobs must NEVER 500 over this.
EMBEDDED_DRIVER: dict = {
    "HULLS": ["brigantine", "caravel", "caravela_redonda", "carrack", "dhow",
              "fluyt", "galiot", "galleass", "galleon", "galley", "junk",
              "latin", "nao", "pinnace", "sloop", "xebec"],
    "DIRS": ["e", "w", "n", "s", "ne", "nw", "se", "sw"],
    "TIER": {"latin": 1, "sloop": 1, "galiot": 1, "pinnace": 1,
             "caravel": 2, "galley": 2, "brigantine": 2, "fluyt": 2,
             "junk": 2, "dhow": 2, "caravela_redonda": 2, "xebec": 2,
             "nao": 3, "carrack": 3, "galleon": 3, "galleass": 3},
    "BANDS": BANDS,
    "POSE": {
        "e": "side-view sailing-right pose",
        "w": "side-view sailing-left pose (the mirrored view of the "
             "reference)",
        "n": ("stern-view sailing-away pose, billowed square sails seen from "
              "behind, lit stern-castle windows"),
        "s": "bow-view approaching pose, bowsprit pointing at the viewer",
        "ne": "three-quarter diagonal view sailing toward the top-right",
        "nw": "three-quarter diagonal view sailing toward the top-left",
        "se": "three-quarter diagonal view sailing toward the bottom-right",
        "sw": "three-quarter diagonal view sailing toward the bottom-left",
    },
    "RIG": {
        "latin": "one mast with a big triangular latin lateen sail "
                 "dominating the profile",
        "sloop": "one mast with a big lateen mainsail, short bowsprit, "
                 "small jib",
        "galiot": "compact hull, one large lateen sail and a short oar bank "
                  "visible at the waterline",
        "pinnace": "small oared boat with two staggered oar banks and a "
                   "bare mast stub carrying the pennant",
        "caravel": "two masts with two large triangular lateen sails, "
                   "rounded high prow",
        "galley": "long low hull with rows of oars at the waterline, one "
                  "lateen mainsail plus a small square topsail",
        "brigantine": "two masts: square course and topsail on the fore "
                      "mast, fore-and-aft gaff spanker on the main",
        "fluyt": "fat-bellied hull, blunt stern, three masts with square "
                 "course and topsail stacks",
        "junk": "three masts with fully-battened rectangular junk sails, "
                "fan-tail stern",
        "dhow": "slim hull with sharp prow and one big triangular lateen "
                "sail",
        "caravela_redonda": "roundish hull, three masts: square course and "
                            "topsail stacks fore and main, lateen mizzen",
        "xebec": "narrow hull, three masts with large overlapping "
                 "triangular lateen sails",
        "nao": "three masts with square course and topsail stacks, tall "
               "fore and aft castles, crow's nests",
        "carrack": "three masts with square sails plus a lateen mizzen, "
                   "very high stern castle",
        "galleon": "three masts with square sails, high stern castle, "
                   "crow's nests, beakhead, dense gunports",
        "galleass": "the longest hull, three lateen-rigged masts and many "
                    "oar stations at the waterline",
    },
    "COMPACT": ("Compact proportions: the whole ship fits within a square "
                "as wide as it is long, compact hull, the outboard rig "
                "overhangs the hull minimally."),
    "STYLE": ("Render it as crisp limited-palette pixel art in the style of "
              "early-90s 16-bit sailing games: billowed canvas sails with "
              "curved highlight and shadow bands following the bulge, dense "
              "wooden hull with visible planking lines, small lit cabin "
              "windows, gunports, a small red pennant flag at the mainmast "
              "top, strong 1-pixel dark outline around the whole sprite, "
              "big chunky pixels, pure white background. No water, no "
              "scenery, no text, no frame."),
    "ICON_STYLE": ("redraw as crisp bold 16-bit game icon, same silhouette "
                   "and recognizability, thick outline, flat colors, "
                   "centered, white background"),
    "ICON_PRIORITY": [
        "anchor", "crown", "skull", "hourglass", "save",
        "coin", "crew", "provisions", "morale", "durability",
        "chest", "scroll", "hammer", "bell",
        "cannon", "hook", "ram", "surrender_flag",
        "compass", "calm", "fair", "strong", "storm",
        "good_wheat", "good_silk", "good_spices", "good_wine",
        "good_salt", "good_dried_fish", "good_timber", "good_iron",
        "trophy",
    ],
    "ICON_PROMPT_OVERRIDES": {
        "compass": ("Redraw this input sprite. Keep the exact same "
                    "silhouette and recognizability. It is a magnetic "
                    "COMPASS: a round brass-rim compass face with a needle "
                    "rose, N/E/S/W letters on the dial — NOT a ship's "
                    "wheel, no spokes, no handles. "),
        "save": ("Redraw this input sprite. Keep the exact same silhouette "
                 "and recognizability. It is a retro FLOPPY DISK (square "
                 "plastic disk with a metal shutter slot and a small "
                 "label) — the game's save glyph, not an inkwell, not a "
                 "quill. "),
        "crew": ("Redraw this input sprite. Keep the exact same silhouette "
                 "and recognizability. It is a SAILOR figure: "
                 "head-and-shoulders bust wearing a round sailor cap, "
                 "distinct face — not a generic blob, not a podium. "),
        "strong": ("Redraw this input sprite. Keep the exact same "
                   "silhouette and recognizability. It is a STRENGTH "
                   "glyph: a bold chevron strength arrows motif (double "
                   "up-chevrons) readable at 32 px — crisp, unambiguous. "),
        "cannon": ("Redraw this input sprite. Keep the exact same "
                   "silhouette and recognizability. It is a full BRONZE "
                   "CANNON on a wooden carriage: long barrel with a muzzle "
                   "ring plus visible wheels — not just a barrel, not a "
                   "wheel alone. "),
        "hook": ("Redraw this input sprite. Keep the exact same silhouette "
                 "and recognizability. It is a curved GRAPPLING BOAT HOOK: "
                 "clear hook silhouette with a strong curve and a point, "
                 "single readable shape. "),
        "good_iron": ("Redraw this input sprite. Keep the exact same "
                      "silhouette and recognizability. It is a stack of "
                      "dark IRON INGOTS (two or three trapezoid metal bars "
                      "stacked) — not a bench, not a stool. "),
        "scroll": ("Redraw this input sprite. Keep the exact same "
                   "silhouette and recognizability. It is a ROLLED "
                   "PARCHMENT SCROLL: a paper roll with curled ends and a "
                   "visible written face — not a chalkboard, not a framed "
                   "board. "),
        "ram": ("Redraw this input sprite. Keep the exact same silhouette "
                "and recognizability. It is a SHIP BOW RAM: a reinforced "
                "bronze beak protruding forward from a short hull segment "
                "at the waterline — the beak is the dominant feature. "),
    },
    "TERRAIN_KEYS": ["hills_plains", "mountains_plains", "ice_plains",
                     "ice_sea", "reef_sea", "rocky_uniform",
                     "plains_uniform"],
    # per-hull sheet jobs (the batch refactor's shape — embedded so the
    # studio survives even if these constants vanish again mid-refactor)
    "SHEET_DIRS": ["w", "n", "s", "sw", "nw"],
    "SHEET_CELLS": {"w": (64, 64), "n": (640, 64), "s": (1216, 64),
                    "sw": (64, 640), "nw": (640, 640)},
    "SHEET_SIZE": (1792, 1152),
}
# Embedded overrides carry no style tail yet (the parsed driver's overrides
# end with + ICON_STYLE) — append it so both shapes are identical.
for _k in EMBEDDED_DRIVER["ICON_PROMPT_OVERRIDES"]:
    EMBEDDED_DRIVER["ICON_PROMPT_OVERRIDES"][_k] += EMBEDDED_DRIVER["ICON_STYLE"]
_DRIVER_SOURCE = "embedded-fallback"
_DRIVER_ERROR: str | None = None

# The driver's terrain texture clauses (function-local, not literal-parseable)
# — the master's proven wording, embedded verbatim.
TERRAIN_TEXTURES = {
    "hills_plains": "low rocky ridge hills over a golden-brown "
                    "dithered plains base",
    "mountains_plains": "tall grey mountain peaks with white snow caps "
                        "over a golden-brown dithered plains base",
    "ice_plains": "a white-blue icy rim band over the golden-brown "
                  "dithered plains base",
    "ice_sea": "a white-blue icy rim band over deep-blue flat sea water",
    "reef_sea": "dark grey reef rocks breaking through deep-blue flat "
                "sea water",
    "rocky_uniform": "a uniform region of bare grey rocky mountain fill "
                     "texture (dense stony ground, no clusters) — every "
                     "patch identical",
    "plains_uniform": "a uniform region of the golden-brown dithered "
                      "plains base texture — every patch identical",
}
TERRAIN_PROMPT_TMPL = ("Redraw this tile sheet. Keep the exact same layout, "
                       "thin patch gaps and region shapes. Restyle both "
                       "textures as rich early-90s 16-bit terrain pixel art: "
                       "{texture}. Crisp limited palette, chunky readable "
                       "pixels, no text, no frame, no scenery beyond the "
                       "tiles.")


def load_driver(repo: str) -> dict:
    """Parse tools/model_pass.py READ-ONLY (ast). NEVER raises: on a torn
    read (the driver is untracked and rewritten by the re-roll round) or a
    shape drift it keeps the last good parse, else the embedded fallback.
    Literal constants via literal_eval; ICON_PROMPT_OVERRIDES (references
    ICON_STYLE by name) via an AST-validated eval."""
    global _DRIVER, _DRIVER_SOURCE, _DRIVER_ERROR
    if _DRIVER is not None and _DRIVER_SOURCE == "parsed":
        return _DRIVER
    path = os.path.join(repo, "tools", "model_pass.py")
    try:
        with open(path, "r", encoding="utf-8") as fh:
            src = fh.read()
        tree = ast.parse(src, filename=path)
        consts: dict = {}       # wanted constants (the returned driver)
        assign_order: list = []  # (name, value_node) in module order
        for node in tree.body:
            targets = []
            if isinstance(node, ast.Assign):
                targets = [t for t in node.targets
                           if isinstance(t, ast.Name)]
            elif isinstance(node, ast.AnnAssign) and isinstance(node.target,
                                                                ast.Name):
                targets = [node.target]
            for t in targets:
                assign_order.append((t.id, node.value))
        # The driver evolves (latest drift: STYLE/ICON_STYLE reference a new
        # CHROMA_BG constant). Collect EVERY module-level constant into the
        # namespace (literal_eval first, then an AST-gated eval against the
        # constants collected so far — string concatenations only, no
        # calls/attributes/subscripts); the driver is the wanted subset.
        # Two passes so later-defined dependencies resolve too.
        def try_assign(name, value_node):
            if name in consts:
                return
            try:
                consts[name] = ast.literal_eval(value_node)
                return
            except (ValueError, TypeError, MemoryError):
                pass
            for n in ast.walk(value_node):  # eval-safety gate
                ok = isinstance(n, (ast.Constant, ast.BinOp, ast.Add,
                                    ast.Load, ast.Dict, ast.Tuple,
                                    ast.List))
                ok = ok or (isinstance(n, ast.Name) and n.id in consts)
                if not ok:
                    return  # unsupported syntax — leave unresolved
            try:
                consts[name] = eval(  # noqa: S307 — gated above
                    compile(ast.Expression(value_node), path, "eval"),
                    {"__builtins__": {}}, dict(consts))
            except Exception:  # noqa: BLE001 — unresolved this pass
                pass
        for _pass in (1, 2):
            for name, value_node in assign_order:
                try_assign(name, value_node)
        missing = [n for n in _LITERAL_NAMES if n not in consts]
        missing += (["ICON_PROMPT_OVERRIDES"]
                    if "ICON_PROMPT_OVERRIDES" not in consts else [])
        if missing:
            raise RuntimeError(f"constants unresolved: {missing}")
        # sanity: the keys default_prompt needs must exist
        for probe in ("POSE", "RIG", "COMPACT", "STYLE", "ICON_STYLE",
                      "TIER"):
            if probe not in consts:
                raise RuntimeError(f"parsed driver lacks {probe}")
        _DRIVER = consts
        _DRIVER_SOURCE = "parsed"
        _DRIVER_ERROR = None
    except Exception as exc:  # noqa: BLE001 — fallback, never raise
        _DRIVER_ERROR = f"{type(exc).__name__}: {exc}"
        if _DRIVER is None:
            _DRIVER = EMBEDDED_DRIVER
            _DRIVER_SOURCE = "embedded-fallback"
            print(f"[studio-chain] driver parse FAILED ({_DRIVER_ERROR}); "
                  f"using embedded fallback prompts", flush=True)
        else:
            print(f"[studio-chain] driver parse FAILED ({_DRIVER_ERROR}); "
                  f"keeping last good parse", flush=True)
    return _DRIVER


def driver_status() -> dict:
    return {"source": _DRIVER_SOURCE, "error": _DRIVER_ERROR}


def flip_x(data: bytes) -> bytes:
    """Horizontal mirror of any readable PNG (indexed 3 / RGB 2 / RGBA 6) —
    the ingestion's mirror_x for e/ne/se display when their files are gone."""
    w, h, px = decode_rgba(data)
    return encode_png(w, h, [list(reversed(row)) for row in px])


# The driver's sheet-prompt template (function-local in model_pass.py,
# not literal-parseable) — proven wording, embedded verbatim; {rig},
# {compact}, {scale}, {chroma} are filled from the parsed driver.
SHEET_PROMPT_TMPL = (
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
    "The small labels above the cells are pre-printed — do NOT draw "
    "them into the sprites; leave the sixth cell empty. "
    "Rig: {rig}. {compact} {scale}"
    "Render every cell as crisp limited-palette pixel art in the "
    "style of early-90s 16-bit sailing games: billowed canvas sails "
    "with curved highlight and shadow bands following the bulge, "
    "dense wooden hull with visible planking lines, small lit cabin "
    "windows, gunports, a small red pennant flag at the mainmast top, "
    "strong 1-pixel dark outline around each sprite, big chunky "
    "pixels, {chroma}. Keep the thin dark dividers. No "
    "water, no scenery, no extra text, no frame.")
SHEET_SCALE_CLAUSE = {
    "pinnace": ("This hull fills about 75% of its cell width in every "
                "cell — a substantial sloop-of-war, NOT a small boat. "),
    "nao": "This hull fills about 85% of its cell. ",
}

# ---- icon group sheets (the driver's icon_group_definitions shape) ----
ICON_GROUP_SHEET_DOC = "icons get the per-hull treatment: one sheet per family"
ICON_SHEET_COLS = 4       # ICON_SHEET_DIRS
ICON_SHEET_TILE = 384
ICON_SHEET_GAP = 48
ICON_SHEET_LABEL_H = 36
ICON_SHEET_MARGIN = 48
ICON_GROUP_STYLE = {
    "goods_staples": "everyday trade commodities, warm rustic palette",
    "goods_crafts": "manufactured wares and crafts, earthy palette",
    "goods_luxury": "luxury and precious goods, rich golds and jewels",
    "weapons_armor": "steel and bronze weapons and armour, cold grey "
                     "metal with leather",
    "figureheads_sails": "ship equipment: carved figureheads and rolled "
                         "sail cloth, carved wood and canvas",
    "battle": "naval combat munitions, dark iron and powder",
    "heraldry_tactics": "heraldic flags and tactical glyphs, bold "
                        "nation colours",
    "ship_life": "shipboard life and status glyphs, warm wood and brass",
    "weather_trends": "weather omens and market trend glyphs, cool "
                      "blues with gold accents",
    "roles_economy": "professions and administration glyphs, brass and "
                     "parchment",
    "currents": "sea current direction arrows, deep blue flow",
    "winds": "wind direction arrows, pale sky blue flow",
}
ICON_CELL_WORDS = {
    "good_dried_fish": "a golden-brown dried fish with clear head and tail",
    "good_salt": "a white salt mound pile",
    "good_wheat": "golden wheat sheaves tied with string",
    "shot_round": "a round cannonball",
    "shot_chain": "a chain shot (two balls linked by a chain)",
    "shot_armor_piercing": "a pointed armour-piercing bolt",
    "shot_grape": "a grape shot cluster of small balls",
    "eq_lucky_charm": "a small lucky charm amulet",
    "save": "a retro floppy disk",
    "compass": "a magnetic compass with needle rose",
    "crew": "a sailor head-and-shoulders with round cap",
    "strong": "double upward strength chevrons",
}


def icon_cell_words(dd: dict, icon_id: str) -> str:
    """The driver's icon_cell_words: curated map, else prefix-strip +
    underscore->space."""
    words = (dd.get("ICON_CELL_WORDS") or {}).get(icon_id) \
        or ICON_CELL_WORDS.get(icon_id)
    if words:
        return words
    words = icon_id
    for prefix in ("good_", "eq_", "flag_", "role_", "formation_",
                   "current_arrow_", "wind_arrow_", "shot_"):
        if words.startswith(prefix):
            words = words[len(prefix):]
            break
    return words.replace("_", " ")


def icon_group_definitions(repo: str) -> list[tuple[str, list[str]]]:
    """All manifest icon ids grouped into the 12 families — the driver's
    icon_group_definitions replicated (read-only manifest glob)."""
    icons_dir = os.path.join(repo, "tools", "ui_art", "icons")
    by_manifest: dict[str, list[str]] = {}
    if os.path.isdir(icons_dir):
        for path in sorted(os.listdir(icons_dir)):
            if not path.endswith(".json"):
                continue
            try:
                with open(os.path.join(icons_dir, path),
                          encoding="utf-8") as fh:
                    doc = json.load(fh)
            except (OSError, ValueError):
                continue
            sprites = doc if isinstance(doc, list) else doc.get("sprites", [])
            by_manifest[path] = [s["id"] for s in sprites]
    if not by_manifest:
        return []
    goods = by_manifest.get("goods.json", [])
    eq = by_manifest.get("equipment.json", [])
    sail_prefixes = ("eq_mermaid", "eq_eagle", "eq_dragon", "eq_albatross",
                     "eq_angel", "eq_golden", "eq_cotton", "eq_matting",
                     "eq_storm", "eq_flemish", "eq_brocade", "eq_red")
    weapons = [i for i in eq if not i.startswith(sail_prefixes)]
    rigging = [i for i in eq if i.startswith(sail_prefixes)]

    def man(name: str) -> list[str]:
        return by_manifest.get(name, [])

    return [
        ("goods_staples", goods[:13]),
        ("goods_crafts", goods[13:27]),
        ("goods_luxury", goods[27:]),
        ("weapons_armor", weapons),
        ("figureheads_sails", rigging),
        ("battle", man("battle.json")),
        ("heraldry_tactics", man("flags.json") + man("formations.json")
         + man("trophy.json")),
        ("ship_life", man("hud.json") + man("meta.json")),
        ("weather_trends", man("weather.json") + man("trends.json")),
        ("roles_economy", man("roles.json") + man("economy.json")),
        ("currents", man("arrows_current.json")),
        ("winds", man("arrows_wind.json")),
    ]


def icon_sheet_layout(count: int):
    """(w, h), [(x0, y0, x1, y1) per icon in reading order] — the driver's
    icon_sheet_layout (4 columns, 384px tiles)."""
    cols = ICON_SHEET_COLS
    rows = (count + cols - 1) // cols
    tile, gap, label_h, margin = (ICON_SHEET_TILE, ICON_SHEET_GAP,
                                  ICON_SHEET_LABEL_H, ICON_SHEET_MARGIN)
    w = margin * 2 + cols * tile + (cols - 1) * gap
    h = margin + rows * (label_h + tile + gap) + gap
    boxes = []
    for i in range(count):
        r, c = divmod(i, cols)
        x = margin + c * (tile + gap)
        y = margin + r * (label_h + tile + gap) + label_h
        boxes.append((x, y, x + tile, y + tile))
    return (w, h), boxes


def icon_sheet_prompt_from(dd: dict, group: str, ids: list[str]) -> str:
    """The driver's icon_sheet_prompt wording from a constants dict."""
    style = (dd.get("ICON_GROUP_STYLE") or ICON_GROUP_STYLE).get(
        group, "consistent 16-bit game icons")
    cells = "; ".join(f"cell {i + 1} ({icon_cell_words(dd, iid)})"
                      for i, iid in enumerate(ids))
    return (
        "Redraw this input sprite sheet. Every cell contains one icon of "
        "the same icon family — redraw ALL of them in one consistent "
        f"style: {style}. "
        f"Cells in reading order: {cells}. "
        "Each icon: bold silhouette, thick 1px dark outline, flat "
        "limited palette, chunky pixels, readable at 32 px, centered in "
        "its cell, " + (dd.get("CHROMA_BG") or "a solid flat chroma-key "
                        "green background (#00ff00)") + ". The small text "
        "labels above the cells are pre-printed — do NOT draw them into "
        "the sprites. Keep the grid positions and the thin dark "
        "dividers; one icon per cell, do not merge, move or add icons. "
        "No water, no scenery, no extra text, no frame.")


def parse_job(job_id: str) -> tuple[str, str | None, str | None]:
    """(family, subject, dir) for all three shapes the store has used:
    - hull_<ship>_<dir>  legacy per-dir jobs (e/ne/se = mirror displays)
    - sheet_<ship>       per-hull 5-cell sheet jobs (the batch refactor)
    - hull_<ship>        the sheet jobs' progress/ledger key (same family)
    - icon_<id> / terrain_<key>
    Unknown shapes raise KeyError (callers guard per job)."""
    if job_id.startswith("sheet_"):
        return "sheet", job_id[len("sheet_"):], None
    if job_id.startswith("hull_"):
        rest = job_id[len("hull_"):]
        ship, _, direction = rest.rpartition("_")
        if ship and direction in EMBEDDED_DRIVER["DIRS"]:
            return "hull", ship, direction
        return "sheet", rest, None  # hull_<ship> — the sheet progress key
    if job_id.startswith("iconsheet_"):
        return "iconsheet", job_id[len("iconsheet_"):], None
    if job_id.startswith("icons_"):
        return "iconsheet", job_id[len("icons_"):], None
    if job_id.startswith("icon_"):
        return "icon", job_id[len("icon_"):], None
    if job_id.startswith("terrain_"):
        return "terrain", job_id[len("terrain_"):], None
    raise KeyError(job_id)


def _hull_prompt_from(d: dict, ship: str, direction: str,
                      stated_px: int | None) -> str:
    """The driver's hull_prompt wording (byte-identical template) built
    from a constants dict — used by default_prompt and reconstruction."""
    pose = d["POSE"][direction]
    rig = d["RIG"][ship]
    prompt = (f"Redraw this input sprite. Keep the exact same "
              f"silhouette, mast count, sail layout, proportions and "
              f"{pose}. Rig: {rig}. {d['COMPACT']} ")
    if stated_px:
        prompt += (f"Ship length about {stated_px} px of the 512 canvas "
                   f"including bowsprit. ")
    return prompt + d["STYLE"]


def sheet_prompt_from(d: dict, ship: str) -> str:
    """The driver's hull_sheet_prompt wording from a constants dict."""
    return SHEET_PROMPT_TMPL.format(
        rig=d["RIG"][ship], compact=d["COMPACT"],
        scale=SHEET_SCALE_CLAUSE.get(ship, ""), chroma=d["CHROMA_BG"])


def default_prompt(job_id: str, repo: str) -> str:
    """Canonical driver prompt, reconstructed from parsed constants.
    Guaranteed non-empty: any reconstruction failure — including an
    unknown job shape — falls back to a generic embedded wording."""
    d = load_driver(repo)
    try:
        fam, subject, direction = parse_job(job_id)
    except KeyError:
        return (f"Redraw this input sprite. Keep the exact same "
                f"silhouette and recognizability. {EMBEDDED_DRIVER['ICON_STYLE']}")
    try:
        if fam == "hull":
            prompt = _hull_prompt_from(d, subject, direction, None)
            if prompt.strip():
                return prompt
        elif fam == "sheet":
            prompt = sheet_prompt_from(d, subject)
            if prompt.strip():
                return prompt
        elif fam == "iconsheet":
            groups = dict(icon_group_definitions(repo))
            ids = groups.get(subject)
            if ids:
                prompt = icon_sheet_prompt_from(d, subject, ids)
                if prompt.strip():
                    return prompt
        elif fam == "icon":
            prompt = d["ICON_PROMPT_OVERRIDES"].get(subject)
            if not prompt:
                prompt = (f"Redraw this input sprite. Keep the exact same "
                          f"silhouette and recognizability. "
                          f"{d['ICON_STYLE']}")
            if prompt.strip():
                return prompt
        else:
            prompt = TERRAIN_PROMPT_TMPL.format(
                texture=TERRAIN_TEXTURES[subject])
            if prompt.strip():
                return prompt
    except Exception as exc:  # noqa: BLE001 — per-job fallback below
        print(f"[studio-chain] prompt reconstruction failed for {job_id} "
              f"({type(exc).__name__}: {exc}); embedded fallback",
              flush=True)
    # embedded fallback (all keys present by construction)
    e = EMBEDDED_DRIVER
    if fam == "hull":
        pose = e["POSE"].get(direction) or e["POSE"]["e"]
        rig = (e["RIG"].get(subject)
               or f"period-appropriate sailing rig for a {subject}")
        return (f"Redraw this input sprite. Keep the exact same "
                f"silhouette, mast count, sail layout, proportions and "
                f"{pose}. Rig: {rig}. {e['COMPACT']} {e['STYLE']}")
    if fam == "sheet":
        return sheet_prompt_from({
            "RIG": {**e["RIG"],
                    subject: e["RIG"].get(
                        subject, f"its period rig, five consistent views")},
            "COMPACT": e["COMPACT"],
            "CHROMA_BG": "a solid flat chroma-key green background "
                         "(#00ff00)",
        }, subject)
    if fam == "iconsheet":
        return (f"Redraw this input sprite sheet. Every cell contains one "
                f"icon of the same icon family — redraw ALL of them in one "
                f"consistent style: "
                f"{(e.get('ICON_GROUP_STYLE') or ICON_GROUP_STYLE).get(subject, 'consistent 16-bit game icons')}. "
                f"Each icon: bold silhouette, thick 1px dark outline, flat "
                f"limited palette, chunky pixels, readable at 32 px, "
                f"centered in its cell, on a solid flat chroma-key green "
                f"background (#00ff00). Keep the grid positions and the "
                f"thin dark dividers. No water, no scenery, no extra text, "
                f"no frame.")
    if fam == "icon":
        return (e["ICON_PROMPT_OVERRIDES"].get(subject)
                or f"Redraw this input sprite. Keep the exact same "
                   f"silhouette and recognizability. {e['ICON_STYLE']}")
    return TERRAIN_PROMPT_TMPL.format(
        texture=TERRAIN_TEXTURES.get(subject, "rich 16-bit terrain "
                                     "textures matching the reference"))


def reconstruct_original(job_id: str, repo: str, rec: dict | None = None):
    """Rebuild the ACTUAL prompt that produced the job's canonical
    (pre-studio) image — the user's edit base. Applies the re-roll round's
    documented calibration from the driver's progress record: label
    'tightened-band' adds the kept `stated_px` clause; 'tightened-identity'
    and plain runs use the plain builders; icons use ICON_PROMPT_OVERRIDES;
    terrain uses the per-sheet clause. Returns (prompt, source) with source
    'reconstructed' (parsed driver wording) or 'default' (embedded
    fallback wording). Never raises, never empty."""
    d = load_driver(repo)
    try:
        fam, subject, direction = parse_job(job_id)
    except KeyError:
        return (f"Redraw this input sprite. Keep the exact same "
                f"silhouette and recognizability. "
                f"{EMBEDDED_DRIVER['ICON_STYLE']}", "default")

    def build(dd: dict) -> str:
        if fam == "hull":
            stated_px = None
            if rec and rec.get("prompt") == "tightened-band":
                stated_px = rec.get("stated_px")
            return _hull_prompt_from(dd, subject, direction, stated_px)
        if fam == "sheet":
            return sheet_prompt_from(dd, subject)
        if fam == "iconsheet":
            groups = dict(icon_group_definitions(repo))
            ids = groups.get(subject) or []
            if ids:
                return icon_sheet_prompt_from(dd, subject, ids)
            return (f"Redraw this input sprite sheet: every cell one icon "
                    f"of the same family, consistent style. No water, no "
                    f"scenery, no extra text, no frame.")
        if fam == "icon":
            ov = dd["ICON_PROMPT_OVERRIDES"].get(subject)
            return (ov or f"Redraw this input sprite. Keep the exact same "
                          f"silhouette and recognizability. "
                          f"{dd['ICON_STYLE']}")
        return TERRAIN_PROMPT_TMPL.format(texture=TERRAIN_TEXTURES[subject])

    try:
        prompt = build(d)
        if prompt.strip():
            return prompt, ("reconstructed"
                            if _DRIVER_SOURCE == "parsed" else "default")
    except Exception as exc:  # noqa: BLE001 — embedded fallback below
        print(f"[studio-chain] original reconstruction failed for {job_id} "
              f"({type(exc).__name__}: {exc}); embedded fallback",
              flush=True)
    return build(EMBEDDED_DRIVER), "default"


def canonical_seed(job_id: str, repo: str) -> int | None:
    """The driver's canonical seed: 1000 + index in its job order.
    Never raises (manifests may be mid-rewrite); None when unknown."""
    try:
        d = load_driver(repo)
        icons_dir = os.path.join(repo, "tools", "ui_art", "icons")
        manifests = {}
        if os.path.isdir(icons_dir):
            for path in sorted(os.listdir(icons_dir)):
                if not path.endswith(".json"):
                    continue
                try:
                    with open(os.path.join(icons_dir, path),
                              encoding="utf-8") as fh:
                        doc = json.load(fh)
                except (OSError, ValueError):
                    continue  # torn manifest read
                sprites = doc if isinstance(doc, list) \
                    else doc.get("sprites", [])
                for s in sprites:
                    manifests[s["id"]] = s
        ids = [i for i in d["ICON_PRIORITY"] if i in manifests]
        ids += [i for i in sorted(manifests) if i not in set(ids)]
        order = ([f"hull_{h}_{dr}" for h in d["HULLS"] for dr in d["DIRS"]]
                 + [f"terrain_{k}" for k in d["TERRAIN_KEYS"]]
                 + [f"icon_{i}" for i in ids[:129]])
        return 1000 + order.index(job_id)
    except Exception:  # noqa: BLE001 — informational value only
        return None


def random_seed() -> int:
    return random.randint(0, 2**31 - 1)


# ------------------------------------------------------------------ runner --


def _cell_green(c: str) -> bool:
    """The driver's green-kill mask test for cell masks (g>=150, r<=110,
    b<=110 — chroma green only; darker model greens survive)."""
    r, g, b = _hex_rgb(c)
    return g >= 150 and r <= 110 and b <= 110


def _aligned_iou(mask_a, mask_b) -> float:
    """The driver's aligned-IoU: normalise each mask's point set to its
    bbox top-left, then intersection over union."""
    sets = []
    for m in (mask_a, mask_b):
        pts = [(x, y) for y in range(len(m)) for x in range(len(m[0]))
               if m[y][x]]
        if not pts:
            return 0.0
        x0 = min(p[0] for p in pts)
        y0 = min(p[1] for p in pts)
        sets.append({(x - x0, y - y0) for x, y in pts})
    inter = len(sets[0] & sets[1])
    union = len(sets[0] | sets[1])
    return inter / max(1, union)


def _run_icon_sheet(job_id: str, subject: str, rec: dict, px, gen_size,
                    stage) -> dict:
    """Per-group icon sheet: the driver's run_icon_sheet_job chain —
    layout, 384px clamped windows, 64px green-killed cell masks vs 32px
    draft masks, aligned-IoU greedy assignment (the model may move icons),
    then per icon: crop -> rembg -> key -> snap -> CANONICAL per-icon
    writes (snapped/icon_<id>.png + debg) plus studio copies."""
    groups = icon_group_definitions(REPO)
    ids = next((ids for g, ids in groups if g == subject), None)
    if not ids:
        raise RuntimeError(f"unknown icon group {subject!r} (no ids)")
    w, h = gen_size
    rec["gen_size"] = [w, h]
    size, boxes = icon_sheet_layout(len(ids))
    if (w, h) != size:
        rec["drift"] = round(w / size[0], 3)
        px = _resize_nearest(px, w, h, size[0], size[1])
    atomic_write(studio_path("gen", job_id), encode_png(size[0], size[1], px))
    windows = []
    for (bx0, by0, bx1, by1) in boxes:
        ccx, ccy = (bx0 + bx1) / 2, (by0 + by1) / 2
        wx0 = max(0, min(size[0] - 384, int(ccx - 192)))
        wy0 = max(0, min(size[1] - 384, int(ccy - 192)))
        windows.append((wx0, wy0, wx0 + 384, wy0 + 384))
    cell_masks = []
    for (wx0, wy0, wx1, wy1) in windows:
        c = crop_rows(px, wx0, wy0, wx1, wy1)
        cw, ch = wx1 - wx0, wy1 - wy0
        if (cw, ch) != (64, 64):
            c = _resize_nearest(c, cw, ch, 64, 64)
        cell_masks.append([[1 if cc is not None and not _cell_green(cc)
                            else 0 for cc in row] for row in c])
    draft_masks = {}
    for icon_id in ids:
        tok_path = os.path.join(REPO, "assets", "ui", "icons",
                                f"{icon_id}.png")
        with open(tok_path, "rb") as fh:
            _, _, tpx = decode_rgba(fh.read())
        draft_masks[icon_id] = [[1 if cc is not None else 0
                                 for cc in row] for row in tpx]

    assignment = {}
    used = set()
    pairs = []
    for ci, mask in enumerate(cell_masks):
        for ii, icon_id in enumerate(ids):
            pairs.append((_aligned_iou(mask, draft_masks[icon_id]), ci, ii))
    for score, ci, ii in sorted(pairs, key=lambda p: -p[0]):
        if ci in used or ii in used:
            continue
        assignment[ids[ii]] = ci
        used.add(ci)
        used.add(ii)
    rec["assignment"] = {iid: list(windows[ci])
                         for iid, ci in assignment.items()}
    block = sorted(_VD.BLOCK_ICON)
    results = {}
    for icon_id in sorted(assignment):
        ci = assignment[icon_id]
        wx0, wy0, wx1, wy1 = windows[ci]
        cell = crop_rows(px, wx0, wy0, wx1, wy1)
        cell_png = encode_png(wx1 - wx0, wy1 - wy0, cell)
        stage(f"rembg icon_{icon_id}")
        debg = key_green_bytes(rembg(cell_png, f"icon_{icon_id}"))
        atomic_write(canonical_path("debg", f"icon_{icon_id}"), debg)
        stage(f"snap icon_{icon_id}")
        grid, metrics = snap(debg, block, band=None, pennant_snap=False)
        png = encode_png(64, 64, grid)
        atomic_write(canonical_path("snapped", f"icon_{icon_id}"), png)
        atomic_write(studio_path("snapped", f"icon_{icon_id}"), png)
        results[icon_id] = {"metrics": metrics}
    rec["results"] = results
    return rec


def run_job(job_id: str, prompt: str, seed: int, on_stage=None) -> dict:
    """One studio generation. Writes studio/{gen,snapped,debg}/<job>.png and
    returns a record (metrics, sizes, seconds). Terrain: gen only."""
    t0 = time.time()
    fam, subject, direction = parse_job(job_id)
    stage = on_stage or (lambda _s: None)

    draft_path = os.path.join(_DRAFTS, job_id + ".png")
    with open(draft_path, "rb") as fh:
        draft_bytes = fh.read()

    stage("generate")
    gen = generate(draft_bytes, prompt, seed)
    rec = {"gen_bytes": len(gen)}

    if fam == "terrain":
        w, h, px = decode_rgba(gen)
        rec["gen_size"] = [w, h]
        if (w, h) != (1024, 512):
            rec["drift"] = round(w / 1024.0, 3)
            px = _resize_nearest(px, w, h, 1024, 512)
        atomic_write(studio_path("gen", job_id), encode_png(len(px[0]),
                                                           len(px), px))
        rec["seconds"] = round(time.time() - t0, 1)
        return rec

    if fam == "iconsheet":
        w, h, px = decode_rgba(gen)
        rec.update(_run_icon_sheet(job_id, subject, rec, px, (w, h), stage))
        rec["seconds"] = round(time.time() - t0, 1)
        return rec

    if fam == "sheet":
        # per-hull 5-cell sheet: one /edit, then per-dir crop -> rembg ->
        # key -> snap. Studio crops land at the legacy per-dir studio paths
        # (hull_<ship>_<dir>.png) so accept's atomic copies point at the
        # canonical per-dir ingestion inputs. The w cell carries the band.
        d = load_driver(REPO)
        sheet_dirs = d.get("SHEET_DIRS") or EMBEDDED_DRIVER["SHEET_DIRS"]
        cells = d.get("SHEET_CELLS") or EMBEDDED_DRIVER["SHEET_CELLS"]
        size = d.get("SHEET_SIZE") or EMBEDDED_DRIVER["SHEET_SIZE"]
        w, h, px = decode_rgba(gen)
        rec["gen_size"] = [w, h]
        sx, sy = w / size[0], h / size[1]
        if abs(sx - round(sx)) > 0.02 or abs(sy - round(sy)) > 0.02:
            rec["drift"] = round(sx, 3)
        atomic_write(studio_path("gen", job_id), gen)
        try:
            band = BANDS[d["TIER"][subject]]
        except Exception:  # noqa: BLE001 — tier unknown mid-refactor
            band = None
        block = sorted(_VD.BLOCK_HULL)
        per_dir = {}
        for direction in sheet_dirs:
            cx, cy = cells[direction]
            x0, y0 = int(cx * sx), int(cy * sy)
            x1, y1 = int((cx + 512) * sx), int((cy + 512) * sy)
            cell = crop_rows(px, x0, y0, x1, y1)
            cw, ch = x1 - x0, y1 - y0
            if (cw, ch) != (512, 512):
                cell = _resize_nearest(cell, cw, ch, 512, 512)
            cell_png = encode_png(512, 512, cell)
            stage(f"rembg {direction}")
            debg = key_green_bytes(rembg(cell_png, f"{job_id}_{direction}"))
            dir_job = f"hull_{subject}_{direction}"
            atomic_write(studio_path("debg", dir_job), debg)
            stage(f"snap {direction}")
            grid, metrics = snap(debg, block,
                                 band=(band if direction == "w" else None),
                                 pennant_snap=True)
            atomic_write(studio_path("snapped", dir_job),
                         encode_png(64, 64, grid))
            per_dir[direction] = {"metrics": metrics}
        rec["per_dir"] = per_dir
        rec["seconds"] = round(time.time() - t0, 1)
        return rec

    stage("rembg")
    debg = rembg(gen, job_id)
    atomic_write(studio_path("gen", job_id), gen)
    atomic_write(studio_path("debg", job_id), debg)
    rec["debg_bytes"] = len(debg)

    stage("snap")
    d = load_driver(REPO)
    block = sorted(_VD.BLOCK_HULL if fam == "hull" else _VD.BLOCK_ICON)
    band = (BANDS[d["TIER"][subject]] if fam == "hull"
            and direction in ("e", "w") else None)
    grid, metrics = snap(debg, block, band=band, pennant_snap=(fam == "hull"))
    rec["metrics"] = metrics
    atomic_write(studio_path("snapped", job_id),
                 encode_png(64, 64, grid))
    rec["seconds"] = round(time.time() - t0, 1)
    return rec
