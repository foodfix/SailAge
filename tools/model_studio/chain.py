#!/usr/bin/env python3
"""SailAge model-studio generation chain — the pixellab family layer.

All four art families drive the build-time pixellab tools IN-PROCESS
(std-lib-only at import; the tools lazy-import PIL themselves):
  - td_<label>   top-down north ships   -> tools/pixellab_pass.py run_topdown
  - fx_<ship>    wake VFX sheets        -> tools/pixellab_vfx_pass.py run_ship
  - ic_<icon>    prompt-only icons      -> tools/pixellab_pass.py run_icon
  - gl_<glyph>   prompt-only glyphs     -> tools/pixellab_pass.py run_glyph
  - coast        the vendored tileset   -> tools/pixellab_pass.py
                                          run_coast_tileset
The legacy TheNoise/ComfyUI icon pipeline (draft -> :8001/edit -> rembg ->
snap, driven by a read-only parse of tools/model_pass.py) is REMOVED
(2026-11-08 user direction — the prompt-only icon/glyph families
replaced it): the icon_* / iconsheet_* / terrain_* job shapes are
unknown here, generate()/rembg()/snap() and the driver parse are gone.

PNG decode/encode: local minimal stdlib writers (indexed type-3 + RGBA
type-6 decode with a truecolor type-2 fallback; 8-bit RGBA filter-0
encode) — shared by the coast strip/mock previews.
"""

from __future__ import annotations

import base64
import json
import os
import random
import re
import struct
import sys
import time
import zlib

# --------------------------------------------------------------- services --


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
    for sub in ("gen", "snapped", "debg", "coast"):
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


COAST_CARD_ID = "coast"
COAST_RAW_DIR_NAME = "tools/assets/pixellab_raw"
COAST_LEDGER = "pixellab_coast_ledger.json"


def coast_repo_raw_dir() -> str:
    return os.path.join(REPO, COAST_RAW_DIR_NAME)


def coast_ledger_path() -> str:
    return os.path.join(coast_repo_raw_dir(), COAST_LEDGER)


def coast_ledger() -> dict:
    with open(coast_ledger_path(), encoding="utf-8") as fh:
        return json.load(fh)


def coast_request_path(tileset_id: str) -> str:
    return os.path.join(coast_repo_raw_dir(),
                        f"tileset_coastline_{tileset_id}_request.json")


def coast_defaults() -> dict:
    """Re-roll defaults from the TRACKED provenance: descriptions/params
    from the vendored request, seed from the ledger. Never the gitignored
    api_key config."""
    tid = coast_ledger()["pixellab"]["tileset_id"]
    with open(coast_request_path(tid), encoding="utf-8") as fh:
        req = json.load(fh)
    return {"tileset_id": tid, "seed": coast_ledger()["pixellab"]["seed"],
            "lower": req["lower_description"],
            "upper": req["upper_description"],
            "transition": req["transition_description"],
            "boundary_seed": req.get("boundary_seed")}


def coast_pending_path() -> str | None:
    """Newest pending re-roll result in the studio cache, or None."""
    d = studio_path("coast", "")
    if not os.path.isdir(d):
        return None
    cands = [os.path.join(d, f) for f in os.listdir(d)
             if f.startswith("tileset_coastline_") and f.endswith(".json")]
    if not cands:
        return None
    return max(cands, key=os.path.getmtime)


def coast_reroll(seed: int | None, style: str | None,
                 poll_status=None) -> dict:
    """One corner-tileset re-roll, in-process via pixellab_pass. `style`
    is the user's free-text clause appended to all three vendored
    descriptions; seed None → the ledger's pinned seed. The raw result
    lands in the studio cache (gitignored) until Accept stages it into
    the vendored store."""
    defaults = coast_defaults()
    px = _pixellab_pass()
    rec = px.run_coast_tileset(
        seed=seed,
        lower=(f"{defaults['lower']}, {style}" if style else None),
        upper=(f"{defaults['upper']}, {style}" if style else None),
        transition=(f"{defaults['transition']}, {style}" if style
                    else None),
        poll_status=poll_status)
    tid = rec["tileset_id"]
    out = studio_path("coast", f"tileset_coastline_{tid}.json")
    atomic_write(out, json.dumps(
        {"tileset_id": tid, "job_id": rec["job_id"], "seed": rec["seed"],
         "payload": rec["payload"], "result": rec["result"]},
        indent=1).encode("utf-8"))
    rec["studio_path"] = out
    return rec


def coast_tiles_of(result: dict) -> dict[int, dict]:
    """wang index -> {corners, w, h, rows} — rows are hex-string pixels
    (chain's decode semantics: "#rrggbb" or None), decoded from a tileset
    result/ledger-shaped payload (tiles[].corners + image.base64)."""
    out = {}
    for tile in result.get("tileset", {}).get("tiles", []):
        c = tile["corners"]
        idx = ((1 if c["NW"] == "upper" else 0)
               + (2 if c["NE"] == "upper" else 0)
               + (4 if c["SW"] == "upper" else 0)
               + (8 if c["SE"] == "upper" else 0))
        w, h, rows = decode_rgba(base64.b64decode(tile["image"]["base64"]))
        out[idx] = {"corners": c, "w": w, "h": h, "rows": rows}
    return out


def coast_strip_png(result: dict) -> bytes:
    """The 16 wang tiles as an 8x2 strip (512x128) — the card thumbnail."""
    tiles = coast_tiles_of(result)
    cell = max(t["w"] for t in tiles.values()) if tiles else 64
    cols, row_count = 8, 2
    rows: list = [[None] * (cols * cell) for _ in range(row_count * cell)]
    for idx, tile in sorted(tiles.items()):
        ox = (idx % cols) * cell
        oy = (idx // cols) * cell
        for y, trow in enumerate(tile["rows"]):
            for x, pxv in enumerate(trow):
                rows[oy + y][ox + x] = pxv
    return encode_png(cols * cell, row_count * cell, rows)


def _png_palette(data: bytes) -> list[str]:
    """Minimal chunk walk: the PLTE entries of an indexed PNG as
    '#rrggbb' strings (the world raster's palette, index order)."""
    pos = 8
    while pos + 8 <= len(data):
        length = int.from_bytes(data[pos:pos + 4], "big")
        ctype = data[pos + 4:pos + 8]
        if ctype == b"PLTE":
            pl = data[pos + 8:pos + 8 + length]
            return [f"#{pl[i]:02x}{pl[i + 1]:02x}{pl[i + 2]:02x}"
                    for i in range(0, length, 3)]
        pos += 12 + length
    return []


def coast_mock_png(result: dict) -> bytes:
    """Wang map mock: a real 12x4-cell crop of the built world (Bay of
    Biscay — north/west-facing coasts) rendered 1:1 with the provided
    tiles through the water-flanking rule. 768x256. Water = wang_0; land
    = the flanking index tile; index 0 (impossible on the built map)
    draws the legacy flat land fill."""
    tiles = coast_tiles_of(result)
    map_path = os.path.join(REPO, "data", "maps", "world.png")
    with open(map_path, "rb") as fh:
        png_bytes = fh.read()
    pal = _png_palette(png_bytes)
    land_hex = pal[2] if len(pal) > 2 else "#7a5c2e"
    mw, mh, map_rows = decode_rgba(png_bytes)
    x0, y0, cw, ch = 2084, 400, 12, 4
    cw = min(cw, mw)
    ch = min(ch, mh)
    rows: list = [[None] * (cw * 64) for _ in range(ch * 64)]
    fallback = "#7a5c2e"
    for cy in range(ch):
        for cx in range(cw):
            x, y = x0 + cx, y0 + cy

            def land(ox: int, oy: int) -> bool:
                yy = y + oy
                if yy < 0 or yy >= mh:
                    return False
                pxv = map_rows[yy][(x + ox) % mw]
                return pxv == land_hex

            if land(0, 0):
                n, s = (not land(0, -1)), (not land(0, 1))
                w, e = (not land(-1, 0)), (not land(1, 0))
                fnw = n or w or (not land(-1, -1))
                fne = n or e or (not land(1, -1))
                fsw = s or w or (not land(-1, 1))
                fse = s or e or (not land(1, 1))
                idx = ((int(not fnw) << 3) + (int(not fne) << 2)
                       + (int(not fsw) << 1) + int(not fse))
                tile = tiles.get(idx)
                if tile is None:  # index 0: the legacy flat fallback
                    for yy in range(64):
                        for xx in range(64):
                            rows[cy * 64 + yy][cx * 64 + xx] = fallback
                    continue
            else:
                tile = tiles.get(0)
            for yy, trow in enumerate(tile["rows"]):
                for xx, pxv in enumerate(trow):
                    rows[cy * 64 + yy][cx * 64 + xx] = pxv
    return encode_png(cw * 64, ch * 64, rows)


def _px_mod():
    """The shared lazy import of tools/pixellab_pass.py (std-lib-only at
    chain import time; PIL inside the tool is lazy too). Used by the
    top-down ship family and the wake VFX family."""
    if "pixellab_pass" in sys.modules:
        return sys.modules["pixellab_pass"]
    tools_dir = os.path.join(REPO, "tools")
    if tools_dir not in sys.path:
        sys.path.insert(0, tools_dir)
    import pixellab_pass  # noqa: PLC0415
    return pixellab_pass


def _vfx_mod():
    """The wake family's lazy import of tools/pixellab_vfx_pass.py (same
    pattern as _px_mod; the VFX tool shares the pass tool's envelope
    helpers but carries its own V5_DESCRIPTION / run_ship)."""
    if "pixellab_vfx_pass" in sys.modules:
        return sys.modules["pixellab_vfx_pass"]
    tools_dir = os.path.join(REPO, "tools")
    if tools_dir not in sys.path:
        sys.path.insert(0, tools_dir)
    import pixellab_vfx_pass  # noqa: PLC0415
    return pixellab_vfx_pass


# ------------------------- top-down north ship family (§4.8 2026-11-07) --
# The studio's top-down path drives tools/pixellab_pass.py --topdown
# IN-PROCESS: ONE straight-overhead north token per ship (canvas = tier
# size), ship-as-drawn — no band/pennant gates (all retired). The runtime
# rotates the token; the card previews the 8 rotations (PIL NEAREST — the
# same resampling family the game pins).

def td_dir():
    return os.path.join(RAW, "pixellab_topdown")


def td_manifest() -> dict:
    path = os.path.join(td_dir(), "pixellab_topdown.json")
    try:
        with open(path, encoding="utf-8") as fh:
            doc = json.load(fh)
        return doc if isinstance(doc, dict) else {}
    except (OSError, ValueError):
        return {}


def td_labels() -> list[str]:
    root = td_dir()
    out = set(td_manifest().keys())
    try:
        for name in sorted(os.listdir(root)):
            if os.path.isdir(os.path.join(root, name)):
                out.add(name)
    except OSError:
        pass
    return sorted(out)


def td_ship_of(label: str) -> str:
    rec = td_manifest().get(label) or {}
    ship = rec.get("ship")
    return str(ship) if ship else label


def td_fallback_prompt(label: str) -> str:
    """The bare last-resort template ({ship} sailing ship) — shown only
    live; the registry tags it source "default" so the state backfill
    never pins it (same never-pin contract as the icon family)."""
    return f"{td_ship_of(label)} sailing ship"


def td_default_prompt(label: str) -> str:
    """The pinned per-ship descriptor + overhead style suffix — the
    free-text edit base. Failure falls back to the manifest's recorded
    description (what actually produced the accepted art)."""
    try:
        mod = _px_mod()
        p = mod._desc_topdown(td_ship_of(label))
        if p and p.strip():
            return p.strip()
    except Exception as exc:  # noqa: BLE001 — manifest fallback below
        print(f"[studio-chain] td default prompt failed for {label} "
              f"({type(exc).__name__}: {exc}); manifest fallback",
              flush=True)
    rec = td_manifest().get(label) or {}
    return str(rec.get("description") or td_fallback_prompt(label))


def td_north_path(label: str) -> str:
    return os.path.join(td_dir(), label, "snapped", "north.png")


def td_exists(label: str) -> bool:
    return os.path.isdir(os.path.join(td_dir(), label))


def td_fleet_labels() -> list[str]:
    """Labels with generation state (≥1 snapped north token) — the
    ingestible fleet."""
    return [lab for lab in td_labels()
            if os.path.isfile(td_north_path(lab))]


def td_generate(label: str, description: str, seed: int,
                on_stage=None) -> dict:
    """One top-down ship job: generate (free-text description + seed) ->
    snap passthrough (byte-identical north token). ~20-60 s of API time;
    the studio worker runs jobs serially so that is fine."""
    t0 = time.time()
    stage = on_stage or (lambda _s: None)
    mod = _px_mod()
    ship = td_ship_of(label)
    stage("posting")
    rec = mod.run_topdown(ship, label=label, description=description,
                          seed=seed,
                          poll_status=lambda s: stage(f"render:{s}"))
    stage("snapping")
    mod.snap_topdown(label)
    ok = os.path.isfile(td_north_path(label))
    return {
        "status": "done" if ok else "partial",
        "job_id": rec.get("job_id"),
        "seed": seed,
        "size": rec.get("size"),
        "description": description,
        "seconds": round(time.time() - t0, 1),
    }


# --------------------- wake VFX family (§4.8 2026-11-08, per-ship) ------
# The studio's wake path drives tools/pixellab_vfx_pass.py IN-PROCESS: ONE
# north wake sheet per SHIP TYPE (all 16 data/ship_types.json ids — each
# wake is authored around that ship's own hull), rendered UNDER the hull —
# ships rotate at runtime, so the sheet rotates with them and only the
# north family ever exists. Re-rolls STAGE into the studio cache (the
# coast pattern) — the canonical raw store model_raw/pixellab_vfx/v6/
# (the ingest's input) is only touched on Accept.

FX_SHIPS = ("latin", "sloop", "caravel", "galley", "brigantine", "nao",
            "carrack", "galleon", "galiot", "galleass", "fluyt", "junk",
            "dhow", "pinnace", "caravela_redonda", "xebec")  # SHIPS
SEA_RGB = (22, 68, 110)  # the wake review blue (tools/preview_topdown.py)


def fx_stage_root() -> str:
    return os.path.join(STUDIO, "fx")


def fx_stage_manifest_path() -> str:
    return os.path.join(fx_stage_root(), "pixellab_vfx.json")


def fx_stage_dir(ship: str) -> str:
    return os.path.join(fx_stage_root(), ship)


def fx_stage_manifest() -> dict:
    """The staging manifest written by pixellab_vfx_pass.run_ship
    (out_root = the studio fx root): ship-keyed records with the effect
    id, quote, and the template-matched anchor_sprite."""
    path = fx_stage_manifest_path()
    try:
        with open(path, encoding="utf-8") as fh:
            doc = json.load(fh)
        return doc if isinstance(doc, dict) else {}
    except (OSError, ValueError):
        return {}


def fx_default_prompt() -> str:
    """The pinned v5 description of record (80-* §4.8 2026-11-07,
    verbatim — the natural-language wake: foam described, not hexed) —
    the free-text edit base."""
    return str(_vfx_mod().V5_DESCRIPTION)


def fx_exists(ship: str) -> bool:
    return os.path.isdir(fx_stage_dir(ship))


def fx_generate(ship: str, description: str, on_stage=None) -> dict:
    """One wake VFX job: POST /v2/vfx (pro artist, game_pack, the ship's
    OWN north token as the sprite input) + poll + raw download into the
    staging root. The envelope has NO seed. ~1-5 min of API time; the
    studio worker runs jobs serially so that is fine."""
    t0 = time.time()
    stage = on_stage or (lambda _s: None)
    mod = _vfx_mod()
    stage("posting")
    rec = mod.run_ship(str(ship), artist="pro",
                       default_description=description,
                       default_name_fmt=f"waterline-v6-north-{ship}-pro",
                       out_root=fx_stage_root())
    ok = rec.get("status") == "completed"
    return {
        "status": "done" if ok else "partial",
        "effect_id": rec.get("effect_id"),
        "quote": rec.get("quoted_generations"),
        "canvas": rec.get("canvas"),
        "description": description,
        "seconds": round(time.time() - t0, 1),
    }


def fx_accept_stage(ship: str) -> None:
    """Accept staging: copy the staged ship dir + its manifest record into
    the canonical raw store model_raw/pixellab_vfx/v6/ (the ingest's
    input). The manifest record merges FIRST (the builder reads it for
    the anchor), then the dir swaps in."""
    import shutil  # noqa: PLC0415
    src = fx_stage_dir(ship)
    if not os.path.isdir(src):
        raise RuntimeError(f"no staged wake re-roll for ship {ship}")
    rec = fx_stage_manifest().get(str(ship))
    if not rec:
        raise RuntimeError(f"staged manifest record missing for {ship}")
    v6_root = os.path.join(RAW, "pixellab_vfx", "v6")
    os.makedirs(v6_root, exist_ok=True)
    v6_path = os.path.join(v6_root, "pixellab_vfx.json")
    try:
        with open(v6_path, encoding="utf-8") as fh:
            v6_m = json.load(fh)
    except (OSError, ValueError):
        v6_m = {}
    v6_m[str(ship)] = rec
    atomic_write(v6_path, json.dumps(v6_m, indent=1, sort_keys=True)
                 .encode("utf-8"))
    dst = os.path.join(v6_root, str(ship))
    tmp = dst + ".stage-tmp"
    shutil.rmtree(tmp, ignore_errors=True)
    shutil.copytree(src, tmp)
    if os.path.isdir(dst):
        shutil.rmtree(dst)
    os.replace(tmp, dst)


def fx_stage_pack(ship: str) -> dict | None:
    """The staged re-roll's render geometry — {sheet_bytes, frame_w,
    frame_h, columns, offset, anchor, gif} read out of the staged game
    pack + staging manifest (the composite preview's source). None when
    nothing is staged."""
    import zipfile  # noqa: PLC0415
    d = fx_stage_dir(ship)
    packs = []
    if os.path.isdir(d):
        packs = sorted(f for f in os.listdir(d) if f.endswith("-game.zip"))
    if not packs:
        return None
    anchor = (fx_stage_manifest().get(str(ship)) or {}).get(
        "anchor_sprite") or {}
    with zipfile.ZipFile(os.path.join(d, packs[0])) as zf:
        manifest = json.loads(zf.read("manifest.json"))
        clip = next(c for c in manifest["clips"] if c["name"] == "behind")
        gif = next((os.path.join(d, f) for f in sorted(os.listdir(d))
                    if f.endswith(".gif")), None)
        return {
            "sheet_bytes": zf.read(clip["sheets"][0]["file"]),
            "frame_w": clip["frame"]["w"], "frame_h": clip["frame"]["h"],
            "columns": clip["sheets"][0]["columns"],
            "offset": clip["offset"], "anchor": anchor, "gif": gif,
        }


def fx_shipped_pack(ship: str) -> dict | None:
    """The committed family's geometry (assets/ui/fx/ + the frame table)
    — the same shape as fx_stage_pack, for the shipped-composite preview
    (what the game shows right now). None before the family ships."""
    fx_dir = os.path.join(REPO, "assets", "ui", "fx")
    try:
        with open(os.path.join(fx_dir, "fx_waterline.json"),
                  encoding="utf-8") as fh:
            table = json.load(fh)
        entry = table.get("ships", {}).get(str(ship)) or {}
        clip = entry.get("sheet") or {}
        if not clip:
            return None
        with open(os.path.join(fx_dir, clip["file"]), "rb") as fh:
            data = fh.read()
    except (OSError, ValueError):
        return None
    return {
        "sheet_bytes": data, "frame_w": clip["frame"]["w"],
        "frame_h": clip["frame"]["h"], "columns": clip["columns"],
        "offset": clip["offset"], "anchor": entry.get("anchor_sprite")
        or {}, "gif": None,
    }


def fx_composite_png(ship: str, pack: dict) -> bytes:
    """Frame 0 of a wake sheet composited UNDER the ship's own north
    token on the review sea blue — the in-game sandwich at native scale
    (the placement rule: sheet top-left = token box top-left +
    (anchor_sprite + offset)). Review aid only; never shipped."""
    from io import BytesIO  # noqa: PLC0415
    from PIL import Image  # noqa: PLC0415
    tok_path = os.path.join(REPO, "assets", "ui", "tokens",
                            f"hull_{ship}.png")
    with open(tok_path, "rb") as fh:
        tok = Image.open(BytesIO(fh.read())).convert("RGBA")
    sheet = Image.open(BytesIO(pack["sheet_bytes"])).convert("RGBA")
    fw, fh = int(pack["frame_w"]), int(pack["frame_h"])
    frame = sheet.crop((0, 0, fw, fh))
    s = tok.width
    cw, ch = max(s, fw) + 16, max(s, fh) + 16
    canvas = Image.new("RGBA", (cw, ch), SEA_RGB + (255,))
    box_x, box_y = (cw - s) // 2, (ch - s) // 2
    off = pack.get("offset") or {}
    anc = pack.get("anchor") or {}
    canvas.alpha_composite(frame, (int(box_x + float(anc.get("x", 0.0))
                                         + float(off.get("x", 0.0))),
                                   int(box_y + float(anc.get("y", 0.0))
                                         + float(off.get("y", 0.0)))))
    canvas.alpha_composite(tok, (box_x, box_y))
    out = BytesIO()
    canvas.save(out, "PNG")
    return out.getvalue()


# --------------- icons + glyphs families (§4.8 2026-11-08, prompt-only) -
# The studio drives tools/pixellab_pass.py IN-PROCESS: ONE prompt-only
# generate-image-v2 job per id (the pinned 4-field envelope — never a
# style_image or reference_images; the doc-first guard list pins which
# ids may generate). ONE card per id (the 2026-11-08 studio
# modernization replaced the TheNoise icon/icon-sheet machinery).
# Re-rolls STAGE into the studio cache (the coast/fx pattern) — the
# canonical raw stores model_raw/pixellab_icons/ + pixellab_glyphs/
# (the ingest's input) are only touched on Accept.

ICON_IDS_CACHE: list[str] | None = None


def icon_ids() -> list[str]:
    """The doc-first GENERATION list — the pinned icon descriptor ids.
    Not the full 122-manifest inventory: the six current_arrow_ siblings
    are derivation-only (derived at ingest from the n/ne bases) and have
    no card — the doc-first rule forbids sending an unpinned prompt."""
    global ICON_IDS_CACHE
    if ICON_IDS_CACHE is None:
        ICON_IDS_CACHE = sorted(_px_mod()._ICON_DESCRIPTORS)
    return list(ICON_IDS_CACHE)


GLYPH_IDS_CACHE: list[str] | None = None


def glyph_ids() -> list[str]:
    """The 6 markers + 6 facility tokens (the pinned descriptor ids)."""
    global GLYPH_IDS_CACHE
    if GLYPH_IDS_CACHE is None:
        GLYPH_IDS_CACHE = sorted(_px_mod()._GLYPH_DESCRIPTORS)
    return list(GLYPH_IDS_CACHE)


def glyph_family(glyph_id: str) -> str:
    return "marker" if glyph_id.startswith("marker_") else "facility"


# -- canonical raw paths (what the ingest walks + the ledger gates) ------

def icon_raw_dir() -> str:
    return _px_mod().ICON_OUT_DIR


def glyph_raw_dir() -> str:
    return _px_mod().GLYPH_OUT_DIR


def icon_manifest() -> dict:
    """The canonical pixellab_icons manifest (id-keyed generation
    records — the exact wording + seed that produced the shipped raw)."""
    path = _px_mod().ICON_MANIFEST
    try:
        with open(path, encoding="utf-8") as fh:
            doc = json.load(fh)
        return doc if isinstance(doc, dict) else {}
    except (OSError, ValueError):
        return {}


def glyph_manifest() -> dict:
    """The canonical pixellab_glyphs manifest (id-keyed)."""
    path = _px_mod().GLYPH_MANIFEST
    try:
        with open(path, encoding="utf-8") as fh:
            doc = json.load(fh)
        return doc if isinstance(doc, dict) else {}
    except (OSError, ValueError):
        return {}


def icon_raw_path(icon_id: str) -> str:
    return os.path.join(icon_raw_dir(), icon_id, "snapped", "icon.png")


def glyph_raw_path(glyph_id: str) -> str:
    return os.path.join(glyph_raw_dir(), glyph_id, "snapped", "icon.png")


# -- staging (the coast/fx pattern) ---------------------------------------

def icon_stage_root() -> str:
    return os.path.join(STUDIO, "icons")


def icon_stage_manifest_path() -> str:
    return os.path.join(icon_stage_root(), "pixellab_icons.json")


def icon_stage_path(icon_id: str) -> str:
    return os.path.join(icon_stage_root(), icon_id, "snapped", "icon.png")


def icon_stage_manifest() -> dict:
    """The staging manifest written by pixellab_pass.run_icon
    (manifest_path = the studio icons root): id-keyed generation
    records, the accept copy's source."""
    path = icon_stage_manifest_path()
    try:
        with open(path, encoding="utf-8") as fh:
            doc = json.load(fh)
        return doc if isinstance(doc, dict) else {}
    except (OSError, ValueError):
        return {}


def glyph_stage_root() -> str:
    return os.path.join(STUDIO, "glyphs")


def glyph_stage_manifest_path() -> str:
    return os.path.join(glyph_stage_root(), "pixellab_glyphs.json")


def glyph_stage_path(glyph_id: str) -> str:
    return os.path.join(glyph_stage_root(), glyph_id, "snapped", "icon.png")


def glyph_stage_manifest() -> dict:
    """The staging manifest written by pixellab_pass.run_glyph (the
    icon staging)."""
    path = glyph_stage_manifest_path()
    try:
        with open(path, encoding="utf-8") as fh:
            doc = json.load(fh)
        return doc if isinstance(doc, dict) else {}
    except (OSError, ValueError):
        return {}


# -- prompts (the pinned descriptors are the free-text edit base) ---------

def icon_default_prompt(icon_id: str) -> str:
    return str(_px_mod()._icon_desc(icon_id))


def glyph_default_prompt(glyph_id: str) -> str:
    return str(_px_mod()._glyph_desc(glyph_id))


# -- generation (in-process; ~$0.008/roll, 20-60 s) -----------------------

def icon_generate(icon_id: str, description: str, seed: int,
                  on_stage=None) -> dict:
    """One icon job: generate + snap passthrough, BOTH into the staging
    store (a discarded/failed re-roll never pollutes the canonical raw
    store — the fx contract)."""
    t0 = time.time()
    stage = on_stage or (lambda _s: None)
    mod = _px_mod()
    stage("posting")
    rec = mod.run_icon(icon_id, description=description, seed=seed,
                       poll_status=lambda s: stage(f"render:{s}"),
                       out_root=icon_stage_root(),
                       manifest_path=icon_stage_manifest_path())
    stage("snapping")
    mod.snap_icon(icon_id, out_root=icon_stage_root())
    ok = os.path.isfile(icon_stage_path(icon_id))
    return {
        "status": "done" if ok else "partial",
        "job_id": rec.get("job_id"),
        "seed": seed,
        "size": rec.get("size"),
        "description": description,
        "seconds": round(time.time() - t0, 1),
    }


def glyph_generate(glyph_id: str, description: str, seed: int,
                   on_stage=None) -> dict:
    """One glyph job — the icon envelope against the family suffix."""
    t0 = time.time()
    stage = on_stage or (lambda _s: None)
    mod = _px_mod()
    stage("posting")
    rec = mod.run_glyph(glyph_id, description=description, seed=seed,
                        poll_status=lambda s: stage(f"render:{s}"),
                        out_root=glyph_stage_root(),
                        manifest_path=glyph_stage_manifest_path())
    stage("snapping")
    mod.snap_glyph(glyph_id, out_root=glyph_stage_root())
    ok = os.path.isfile(glyph_stage_path(glyph_id))
    return {
        "status": "done" if ok else "partial",
        "job_id": rec.get("job_id"),
        "seed": seed,
        "size": rec.get("size"),
        "description": description,
        "seconds": round(time.time() - t0, 1),
    }


# -- accept staging (canonical swap + the ingest gate reads it) -----------

def _copy_stage_into(canonical_root: str, stage_dir_of, stage_manifest,
                     canonical_manifest_path, job_id: str) -> None:
    """Shared accept copy: the staged id dir (raw + snapped) + its
    manifest record move into the canonical raw store (the ingest's
    input). The manifest record merges FIRST, then the dir swaps in
    (the fx accept order)."""
    import shutil  # noqa: PLC0415
    src = stage_dir_of(job_id)
    if not os.path.isdir(src):
        raise RuntimeError(f"no staged re-roll for {job_id}")
    rec = stage_manifest().get(job_id)
    if not rec:
        raise RuntimeError(f"staged manifest record missing for {job_id}")
    os.makedirs(canonical_root, exist_ok=True)
    try:
        with open(canonical_manifest_path, encoding="utf-8") as fh:
            canonical = json.load(fh)
    except (OSError, ValueError):
        canonical = {}
    canonical[job_id] = rec
    atomic_write(canonical_manifest_path,
                 json.dumps(canonical, indent=1, ensure_ascii=False)
                 .encode("utf-8"))
    dst = os.path.join(canonical_root, job_id)
    tmp = dst + ".stage-tmp"
    shutil.rmtree(tmp, ignore_errors=True)
    shutil.copytree(src, tmp)
    if os.path.isdir(dst):
        shutil.rmtree(dst)
    os.replace(tmp, dst)


def _accept_stage(canonical_root: str, stage_root: str, stage_manifest,
                  stage_manifest_path: str, job_id: str) -> None:
    """Accept one staged re-roll into the canonical store, then drop the
    staged dir + record (a stale stage would masquerade as a pending
    re-roll)."""
    _copy_stage_into(canonical_root,
                     lambda jid: os.path.join(stage_root, jid),
                     stage_manifest, stage_manifest_path, job_id)
    staged = stage_manifest()
    if job_id in staged:
        del staged[job_id]
        atomic_write(stage_manifest_path,
                     json.dumps(staged, indent=1, ensure_ascii=False)
                     .encode("utf-8"))
    import shutil  # noqa: PLC0415
    shutil.rmtree(os.path.join(stage_root, job_id), ignore_errors=True)


def icon_accept_stage(icon_id: str) -> None:
    _accept_stage(icon_raw_dir(), icon_stage_root(), icon_stage_manifest,
                  icon_stage_manifest_path(), icon_id)


def glyph_accept_stage(glyph_id: str) -> None:
    _accept_stage(glyph_raw_dir(), glyph_stage_root(), glyph_stage_manifest,
                  glyph_stage_manifest_path(), glyph_id)


def parse_job(job_id: str) -> tuple[str, str | None, str | None]:
    """(family, subject, dir) for the live job shapes:
    - td_<label>         top-down north ship jobs (§4.8 2026-11-07)
    - fx_<ship>          wake VFX jobs, ship ∈ data/ship_types.json
                         (the per-ship wake revision, §4.8 2026-11-08)
    - ic_<icon_id>       prompt-only icon jobs (§4.8 2026-11-08, one
                         card per id — the studio modernization)
    - gl_<glyph_id>      prompt-only marker/facility jobs (same)
    - icon_<id> / iconsheet_<group> / terrain_<key>
    The retired shapes (px_<label> oblique ships, hull_<ship>_<dir>,
    sheet_<ship>) are UNKNOWN since the 2026-11-07 removal — they raise
    KeyError, and the registry skips their draft files by prefix.
    Unknown shapes raise KeyError (callers guard per job)."""
    if job_id.startswith("td_"):
        return "topdown", job_id[len("td_"):], None
    if job_id.startswith("fx_"):
        return "fx", job_id[len("fx_"):], None
    if job_id.startswith("ic_"):
        return "icons", job_id[len("ic_"):], None
    if job_id.startswith("gl_"):
        return "glyphs", job_id[len("gl_"):], None
    if job_id.startswith("iconsheet_"):
        return "iconsheet", job_id[len("iconsheet_"):], None
    if job_id.startswith("icons_"):
        return "iconsheet", job_id[len("icons_"):], None
    if job_id.startswith("icon_"):
        return "icon", job_id[len("icon_"):], None
    if job_id.startswith("terrain_"):
        return "terrain", job_id[len("terrain_"):], None
    raise KeyError(job_id)


def default_prompt(job_id: str, repo: str) -> str:
    """Canonical driver prompt, reconstructed from parsed constants.
    Guaranteed non-empty: any reconstruction failure — including an
    unknown job shape — falls back to a generic embedded wording."""
    if job_id.startswith("fx_"):
        return fx_default_prompt()
    if job_id.startswith("td_"):
        return td_default_prompt(job_id[len("td_"):])
    if job_id.startswith("ic_"):
        return icon_default_prompt(job_id[len("ic_"):])
    if job_id.startswith("gl_"):
        return glyph_default_prompt(job_id[len("gl_"):])
def random_seed() -> int:
    return random.randint(0, 2**31 - 1)


