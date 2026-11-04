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
    tools_dir = os.path.join(repo, "tools")
    if tools_dir not in sys.path:
        sys.path.insert(0, tools_dir)
    import validate_data as _vd_mod  # noqa: PLC0415 — main-repo import
    _VD = _vd_mod


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


# -------------------------------------------------- driver prompt parsing ---

_LITERAL_NAMES = ("HULLS", "DIRS", "TIER", "BANDS", "POSE", "RIG", "COMPACT",
                  "STYLE", "ICON_STYLE", "ICON_PRIORITY", "TERRAIN_KEYS")
_DRIVER: dict | None = None

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
    """Parse tools/model_pass.py READ-ONLY (ast). Literal constants via
    literal_eval; ICON_PROMPT_OVERRIDES (references ICON_STYLE by name) via
    an AST-validated eval. Raises when the driver's constant surface drifts."""
    global _DRIVER
    if _DRIVER is not None:
        return _DRIVER
    path = os.path.join(repo, "tools", "model_pass.py")
    with open(path, "r", encoding="utf-8") as fh:
        src = fh.read()
    tree = ast.parse(src, filename=path)
    consts: dict = {}
    overrides_node = None
    for node in tree.body:
        targets = []
        if isinstance(node, ast.Assign):
            targets = [t for t in node.targets if isinstance(t, ast.Name)]
        elif isinstance(node, ast.AnnAssign) and isinstance(node.target,
                                                            ast.Name):
            targets = [node.target]
        for t in targets:
            if t.id in _LITERAL_NAMES:
                consts[t.id] = ast.literal_eval(node.value)
            elif t.id == "ICON_PROMPT_OVERRIDES":
                overrides_node = node.value
    missing = [n for n in _LITERAL_NAMES if n not in consts]
    if missing or overrides_node is None:
        raise RuntimeError(
            f"model_pass.py constants drifted; missing: {missing} "
            f"(overrides found: {overrides_node is not None})")
    for node in ast.walk(overrides_node):  # eval-safety gate
        ok = isinstance(node, (ast.Constant, ast.BinOp, ast.Add, ast.Load,
                               ast.Dict, ast.Tuple, ast.List))
        ok = ok or (isinstance(node, ast.Name) and node.id == "ICON_STYLE")
        if not ok:
            raise RuntimeError(
                f"ICON_PROMPT_OVERRIDES holds unsupported syntax "
                f"{type(node).__name__}")
    consts["ICON_PROMPT_OVERRIDES"] = eval(  # noqa: S307 — AST-gated above
        compile(ast.Expression(overrides_node), path, "eval"),
        {"__builtins__": {}}, {"ICON_STYLE": consts["ICON_STYLE"]})
    _DRIVER = consts
    return consts


def parse_job(job_id: str) -> tuple[str, str | None, str | None]:
    """(family, subject, dir) — hull_<ship>_<dir> / icon_<id> / terrain_<key>."""
    if job_id.startswith("hull_"):
        ship, direction = job_id[len("hull_"):].rsplit("_", 1)
        return "hull", ship, direction
    if job_id.startswith("icon_"):
        return "icon", job_id[len("icon_"):], None
    if job_id.startswith("terrain_"):
        return "terrain", job_id[len("terrain_"):], None
    raise KeyError(job_id)


def default_prompt(job_id: str, repo: str) -> str:
    """Canonical driver prompt, reconstructed from parsed constants."""
    d = load_driver(repo)
    fam, subject, direction = parse_job(job_id)
    if fam == "hull":
        pose = d["POSE"][direction]
        rig = d["RIG"][subject]
        return (f"Redraw this input sprite. Keep the exact same "
                f"silhouette, mast count, sail layout, proportions and "
                f"{pose}. Rig: {rig}. {d['COMPACT']} {d['STYLE']}")
    if fam == "icon":
        return (d["ICON_PROMPT_OVERRIDES"].get(subject)
                or f"Redraw this input sprite. Keep the exact same "
                   f"silhouette and recognizability. {d['ICON_STYLE']}")
    return TERRAIN_PROMPT_TMPL.format(texture=TERRAIN_TEXTURES[subject])


def canonical_seed(job_id: str, repo: str) -> int | None:
    """The driver's canonical seed: 1000 + index in its job order."""
    d = load_driver(repo)
    icons_dir = os.path.join(repo, "tools", "ui_art", "icons")
    manifests = {}
    if os.path.isdir(icons_dir):
        for path in sorted(os.listdir(icons_dir)):
            if not path.endswith(".json"):
                continue
            with open(os.path.join(icons_dir, path), encoding="utf-8") as fh:
                doc = json.load(fh)
            sprites = doc if isinstance(doc, list) else doc.get("sprites", [])
            for s in sprites:
                manifests[s["id"]] = s
    ids = [i for i in d["ICON_PRIORITY"] if i in manifests]
    ids += [i for i in sorted(manifests) if i not in set(ids)]
    order = ([f"hull_{h}_{dr}" for h in d["HULLS"] for dr in d["DIRS"]]
             + [f"terrain_{k}" for k in d["TERRAIN_KEYS"]]
             + [f"icon_{i}" for i in ids[:129]])
    try:
        return 1000 + order.index(job_id)
    except ValueError:
        return None


def random_seed() -> int:
    return random.randint(0, 2**31 - 1)


# ------------------------------------------------------------------ runner --


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
