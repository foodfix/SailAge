#!/usr/bin/env python3
"""PixelLab hull-token generation pass — build-time SaaS backend.

Top-down mode (2026-11-07 amendment, the shipping path): ONE straight-
overhead north token per ship via `POST /generate-image-v2`, canvas from
the ship's tier (t1 32 / t2 48 / t3 64). Raw PNGs land gitignored under
model_raw/pixellab_topdown/<ship>/ plus a manifest; raw model output is
never committed (90-* §9.2). The key is read from the PIXELLAB_API_KEY
environment variable or the gitignored tools/pixellab_config.json — never
committed.

Usage:
  python3 tools/pixellab_pass.py --topdown run [ship ...]   # default: all 16
  python3 tools/pixellab_pass.py --topdown snap [ship ...]
  python3 tools/pixellab_pass.py --topdown status

Icon mode (2026-11-08, 80-* §4.8 semantic-icon amendment): prompt-only
generate-image-v2, one 64x64 job per icon id, seed 92000, rewritten
object-spec prompts (no hull heritage). Raws land gitignored under
model_raw/pixellab_icons/<id>/ plus a manifest; only ids with a pinned
_ICON_DESCRIPTORS entry may generate (doc-first guard).
  python3 tools/pixellab_pass.py --icons run [id ...]
  python3 tools/pixellab_pass.py --icons snap [id ...]
  python3 tools/pixellab_pass.py --icons status

Glyph mode (2026-11-08, 80-* §4.8 marker/facility amendment): the same
prompt-only 64x64 envelope for the 6 markers + 6 facility tokens under
two rewritten family suffixes (MARKER_SUFFIX / FACILITY_SUFFIX, no icon
heritage); raws land gitignored under model_raw/pixellab_glyphs/<id>/.
  python3 tools/pixellab_pass.py --glyphs run [id ...]
  python3 tools/pixellab_pass.py --glyphs snap [id ...]
  python3 tools/pixellab_pass.py --glyphs status

Legacy Pro-Flash 8-dir hull mode (RETIRED by the 2026-11-07 top-down
amendment — kept only for history/re-download of the old raws):
  python3 tools/pixellab_pass.py run [ship ...]
  python3 tools/pixellab_pass.py status
The coast-tileset path is untouched and stays pinned for the studio.
"""
from __future__ import annotations

import base64  # noqa: PLC0415
import json
import os
import sys
import time
import urllib.request

REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
API = "https://api.pixellab.ai/v2"
OUT_DIR = os.path.join(REPO, "tools", "ui_art", "model_raw", "pixellab")
MANIFEST = os.path.join(OUT_DIR, "pixellab.json")
DIRS = ("north", "north-east", "north-west", "south", "south-east",
        "south-west", "east", "west")
POLL_S, POLL_MAX = 5, 600

# ---- top-down mode pins (80-* §4.8, 2026-11-07 amendment) -------------
# Canvas = tier table (pinned); no new data field — tier comes from
# data/ship_types.json.
TIER_SIZE = {1: 32, 2: 48, 3: 64}
TOPDOWN_OUT_DIR = os.path.join(REPO, "tools", "ui_art", "model_raw",
                               "pixellab_topdown")
TOPDOWN_MANIFEST = os.path.join(TOPDOWN_OUT_DIR, "pixellab_topdown.json")
TOPDOWN_SEED = 91000
# Shared style suffix, pinned verbatim (80-* §4.8, 2026-11-07
# visibility rewrite of the same-day first overhead suffix — user
# direction: side-view-only clauses removed because a straight
# bird's-eye view cannot show them — multi-strake side planking →
# deck planking, gunwale/sheer trim → hull rim, gunport row and
# lit cabin windows dropped, sail billow shading dropped in favor
# of the flat-panels-over-deck top-down game convention; gold trim
# dropped outright, t3-only in the authored maps). Identity prefix
# (name + rig) is prepended, comma-joined; per-ship clause
# insertions (_TOPDOWN_CLAUSES) sit between rig and suffix; the
# pinnace full variant (_TOPDOWN_VARIANTS) replaces the whole
# composed description.
TOPDOWN_SUFFIX = (
    ", wooden sailing ship seen from directly overhead, straight "
    "top-down bird's-eye view, hull axis vertical with the bow "
    "pointing to the top edge of the canvas, wooden deck planking "
    "bands in several warm brown tones between the masts, dark rim "
    "along the hull outline, sails drawn as flat pale panels laid "
    "over the deck following the rig — wide rectangles for square "
    "sails, triangles for lateen sails — the top-down game-sprite "
    "convention, masts as small round dots with thin yard lines, "
    "thin dark rigging ropes to the bowsprit and hull sides, "
    "raised stern cabin roof and deck hatches visible from above, "
    "small red pennant streaming from the mainmast top, retro "
    "16-bit sailing ship sprite in the style of classic 1990s "
    "naval adventure games like Uncharted Waters 2 / New Horizons, "
    "dark 1-pixel silhouette outline, transparent background.")

# Per-ship clause insertions, pinned verbatim (80-* §4.8, the
# 2026-11-07 visibility rewrite) — placed between the rig string
# and the suffix; oars are overhead-visible identity, junk battens
# disambiguate the sail panels.
_TOPDOWN_CLAUSES: dict[str, str] = {
    "galiot": ", long oars fanned out along both hull sides",
    "galley": ", long oars fanned out along both hull sides",
    "galleass": ", long oars fanned out along both hull sides",
    "junk": ", each sail panel crossed by thin horizontal batten lines",
}

# Pinnace full variant, pinned verbatim (80-* §4.8, the 2026-11-07
# visibility rewrite) — no mast and no sails, so the suffix's
# sail/mast/rigging/pennant clauses are replaced wholesale.
_TOPDOWN_VARIANTS: dict[str, str] = {
    "pinnace": (
        "Pinnace ship, tiny open rowing craft, oars only, no mast, "
        "no sails, wooden boat seen from directly overhead, straight "
        "top-down bird's-eye view, hull axis vertical with the bow "
        "pointing to the top edge of the canvas, wooden hull interior "
        "with rowing benches in warm brown tones, dark rim along the "
        "hull outline, long oars fanned out along both hull sides, "
        "retro 16-bit game sprite in the style of classic 1990s "
        "naval adventure games like Uncharted Waters 2 / New "
        "Horizons, dark 1-pixel silhouette outline, transparent "
        "background."),
}

# Per-ship visual descriptors (identity payload). Derived from the
# deterministic manifest rig strings (hulls.json) + §4.8 craft vocabulary.
# Pinned per the concrete-numbers rule; amendment = edit here + docs.
_SUFFIX = (" wooden sailing ship, dense multi-strake hull planking, "
           "billowed sails with folded shading, thin rigging ropes, "
           "small red pennant at the mainmast top, visible deck planking "
           "with stern cabin, bowsprit at the bow, game sprite, "
           "transparent background.")
# Trial 2 (2026-11-06, user direction): full §4.8.6 craft vocabulary —
# candidate for the pinned descriptor set, pending sheet-59 verdict.
_DESCRIPTORS: dict[str, str] = {
    "brigantine":
        "Brigantine sailing ship, two masts with square sails, long low "
        "hull of warm brown wood, multi-strake planking bands in several "
        "wood tones, dark gunwale, gold trim line along the sheer, "
        "gunport row with tiny dark ports, stern cabin with small lit "
        "windows, square sails billowed with three folded shading bands "
        "and one bright highlight arc each, thin dark rigging ropes to "
        "bowsprit and hull, small red pennant at the mainmast top, deck "
        "planking and deck structures visible from above, dark 1-pixel "
        "silhouette outline, rich 16-bit game pixel art, transparent "
        "background.",
}
# Optional view override for view trials (default: high top-down — the
# trial-4 winner, user direction 2026-11-06). No style image, ever.
VIEW = os.environ.get("PIXELLAB_VIEW", "high top-down")
# Shared craft+style suffix (pinned verbatim, 80-* §4.8 2026-11-06): one
# wording for all 16 ships = the style-consistency anchor. Identity comes
# from the per-ship prefix (name + rig); NO style_image is ever sent.
_STYLE_SUFFIX = (
    ", wooden sailing ship with dense multi-strake planking bands in "
    "several wood tones, dark gunwale, gold trim line along the sheer, "
    "gunport row with tiny dark ports, stern cabin with small lit "
    "windows, sails billowed with three folded shading bands and one "
    "bright highlight arc each, thin dark rigging ropes to bowsprit and "
    "hull, small red pennant at the mainmast top, deck planking and "
    "deck structures visible from above, retro 16-bit sailing ship "
    "sprite in the style of classic 1990s naval adventure games like "
    "Uncharted Waters 2 / New Horizons, dark 1-pixel silhouette "
    "outline, transparent background.")


def _desc(ship: str) -> str:
    if ship in _DESCRIPTORS:
        return _DESCRIPTORS[ship]
    with open(os.path.join(REPO, "data", "ship_types.json"),
              encoding="utf-8") as fh:
        types = {s["id"]: s for s in json.load(fh)["ship_types"]}
    with open(os.path.join(REPO, "tools", "ui_art", "hulls", "rig.json"),
              encoding="utf-8") as fh:
        rigs = json.load(fh)["hulls"]
    if isinstance(rigs, list):
        h = next((e for e in rigs if e.get("id") == ship), {})
    else:
        h = rigs.get(ship, {})
    rig = h.get("rig", "sailing rig")
    name = types.get(ship, {}).get("name", {}).get("en", ship)
    return f"{name} sailing ship, {rig}{_STYLE_SUFFIX}"


def _desc_topdown(ship: str) -> str:
    """Top-down identity: {Name-en} sailing ship, {rig} (rig.json)
    + per-ship clause + the pinned overhead suffix (80-* §4.8, the
    2026-11-07 visibility rewrite). The pinnace full variant
    replaces the whole composed description. The oblique brigantine
    trial descriptor does NOT apply here."""
    if ship in _TOPDOWN_VARIANTS:
        return _TOPDOWN_VARIANTS[ship]
    with open(os.path.join(REPO, "data", "ship_types.json"),
              encoding="utf-8") as fh:
        types = {s["id"]: s for s in json.load(fh)["ship_types"]}
    with open(os.path.join(REPO, "tools", "ui_art", "hulls", "rig.json"),
              encoding="utf-8") as fh:
        rigs = json.load(fh)["hulls"]
    if isinstance(rigs, list):
        h = next((e for e in rigs if e.get("id") == ship), {})
    else:
        h = rigs.get(ship, {})
    rig = h.get("rig", "sailing rig")
    name = types.get(ship, {}).get("name", {}).get("en", ship)
    clause = _TOPDOWN_CLAUSES.get(ship, "")
    return f"{name} sailing ship, {rig}{clause}{TOPDOWN_SUFFIX}"


def _tier_of(ship: str) -> int:
    with open(os.path.join(REPO, "data", "ship_types.json"),
              encoding="utf-8") as fh:
        types = {s["id"]: s for s in json.load(fh)["ship_types"]}
    return int(types[ship]["tier"])


def _size_of(ship: str) -> int:
    return TIER_SIZE[_tier_of(ship)]


def _job_image_bytes(job: dict) -> bytes:
    """Extract the PNG from a completed generate-image-v2 background job.
    The schema only promises `last_response` as an opaque object; handle
    the shapes the API has used: image.base64, images[0].base64, or an
    image/url field carrying a downloadable link."""
    lr = job.get("last_response") or {}
    for cand in ([lr.get("image")] if isinstance(lr.get("image"), dict)
                 else []) + list(lr.get("images") or []):
        if isinstance(cand, dict) and cand.get("base64"):
            return base64.b64decode(cand["base64"])
    for key in ("image_url", "url", "result_url"):
        v = lr.get(key)
        if isinstance(v, str) and v:
            return _download(v)
    raise RuntimeError(f"no image in completed job "
                       f"(last_response keys: {sorted(lr)})")


def run_topdown(ship: str, label: str | None = None,
                description: str | None = None, seed: int | None = None,
                poll_status=None) -> dict:
    """One generate-image-v2 generation (the pinned 4-field envelope — no
    style_image, no reference_images; 80-* §4.8 2026-11-07) + raw north
    download. The studio (tools/model_studio) calls this in-process with
    an explicit description (the user's edit) + seed; the CLI keeps the
    pinned defaults. poll_status, when given, receives each background
    job status string for the studio's stage ticker."""
    size = _size_of(ship)
    payload = {
        "description": description or _desc_topdown(ship),
        "image_size": {"width": size, "height": size},
        "no_background": True,
        "seed": TOPDOWN_SEED if seed is None else int(seed),
    }
    print(f"[pixellab-topdown {ship}] POST generate-image-v2 "
          f"({size}x{size}) ...", flush=True)
    created = _post("/generate-image-v2", payload)
    job_id = created["background_job_id"]
    usage = created.get("usage") or {}
    print(f"    job={job_id} usage={json.dumps(usage)}", flush=True)

    deadline = time.time() + POLL_MAX
    job = {}
    while time.time() < deadline:
        time.sleep(POLL_S)
        job = _get(f"/background-jobs/{job_id}")
        if poll_status is not None:
            try:
                poll_status(str(job.get("status")))
            except Exception:  # noqa: BLE001 — the ticker must never kill a job
                pass
        if job.get("status") in ("completed", "failed"):
            break
        print(f"    status={job.get('status')}", flush=True)
    if job.get("status") != "completed":
        raise RuntimeError(f"{ship}: job {job_id} status="
                           f"{job.get('status')!r} "
                           f"(last: {json.dumps(job)[:300]})")

    dest = label or ship
    dest_dir = os.path.join(TOPDOWN_OUT_DIR, dest)
    os.makedirs(dest_dir, exist_ok=True)
    png = _job_image_bytes(job)
    with open(os.path.join(dest_dir, "north.png"), "wb") as fh:
        fh.write(png)
    rec = {"job_id": job_id, "description": payload["description"],
           "seed": payload["seed"], "size": size, "ship": ship,
           "label": dest, "bytes": {"north": len(png)},
           "usage": usage, "job_status": job.get("status")}
    os.makedirs(TOPDOWN_OUT_DIR, exist_ok=True)
    manifest = {}
    if os.path.isfile(TOPDOWN_MANIFEST):
        with open(TOPDOWN_MANIFEST, encoding="utf-8") as fh:
            manifest = json.load(fh)
    manifest[dest] = rec
    with open(TOPDOWN_MANIFEST, "w", encoding="utf-8") as fh:
        json.dump(manifest, fh, indent=1, ensure_ascii=False)
    return rec


def snap_topdown(ship: str) -> None:
    """Ship-as-drawn passthrough: the RAW north token copies
    BYTE-IDENTICAL into <label>/snapped/north.png for ingest naming.
    Gate: canvas fit (exact tier size S×S). No resize, no quantize,
    no pennant remap — the model's pixels are the shipped pixels."""
    from PIL import Image  # noqa: PLC0415
    src_dir = os.path.join(TOPDOWN_OUT_DIR, ship)
    src = os.path.join(src_dir, "north.png")
    if not os.path.exists(src):
        raise SystemExit(f"{ship}: no raw north token at {src} — "
                         f"run --topdown run first")
    want = _size_of(ship)
    img = Image.open(src)
    w, h = img.size
    fit = (w, h) == (want, want)
    dst_dir = os.path.join(src_dir, "snapped")
    os.makedirs(dst_dir, exist_ok=True)
    with open(src, "rb") as fh:
        data = fh.read()
    with open(os.path.join(dst_dir, "north.png"), "wb") as fh:
        fh.write(data)
    print(f"  {ship}: raw copy {w}x{h} want={want}x{want} fit={fit}",
          flush=True)


def run_topdown_fleet(ships: list[str], seed: int | None = None) -> None:
    for i, ship in enumerate(ships, 1):
        raw = os.path.join(TOPDOWN_OUT_DIR, ship, "north.png")
        if os.path.isfile(raw):
            # resumable: the raw file IS the artifact — a re-roll deletes
            # it (or names the ship explicitly on the CLI)
            print(f"[pixellab-topdown {i}/{len(ships)}] {ship} already has "
                  f"raw north.png — skipped (delete it to re-roll)",
                  flush=True)
            continue
        rec = run_topdown(ship, seed=seed)
        print(f"[pixellab-topdown {i}/{len(ships)}] {ship} saved "
              f"north.png ({rec['bytes']['north']} bytes)", flush=True)
    print(f"[pixellab-topdown] manifest -> {TOPDOWN_MANIFEST}", flush=True)


def status_topdown() -> None:
    if not os.path.exists(TOPDOWN_MANIFEST):
        print("no top-down manifest yet")
        return
    with open(TOPDOWN_MANIFEST, encoding="utf-8") as fh:
        m = json.load(fh)
    for ship, e in m.items():
        print(f"{ship:18s} size={e['size']} seed={e['seed']} "
              f"job={e['job_id'][:12]}…")
    print(f"{len(m)} ships")


# ---- icon pass pins (80-* §4.8, the 2026-11-08 semantic-icon
# amendment) -------------------------------------------------------------
# Prompt-only generate-image-v2, one 64x64 job per icon id, seed distinct
# from the hulls' 91000. Descriptors are REWRITTEN object specs — no hull
# vocabulary. Goods/equipment carry their en name (data JSONs) as the
# identity prefix, prepended by the composer; pure glyph ids carry the
# whole object spec. A full-variant replacement exists for objects the
# suffix would fight (none yet).
ICON_SEED = 92000
ICON_SIZE = 64
ICON_OUT_DIR = os.path.join(REPO, "tools", "ui_art", "model_raw",
                            "pixellab_icons")
ICON_MANIFEST = os.path.join(ICON_OUT_DIR, "pixellab_icons.json")
# Shared icon suffix, pinned verbatim (80-* §4.8, 2026-11-08; strictly
# flat front-facing for EVERY id — user direction; UW2 anchor kept —
# user direction; NO hull heritage).
ICON_SUFFIX = (
    ", single centered game UI icon, flat front-facing view, the object "
    "fills about 70% of the canvas and stays fully inside the frame, "
    "bold readable silhouette, flat cel shading with two or three "
    "shading bands, dark 1-pixel silhouette outline on the outer edge "
    "only, no scenery, no background elements, no cropping, no text, "
    "no gradients, limited retro palette in warm midtones, retro "
    "16-bit pixel-art game icon in the style of classic 1990s naval "
    "adventure games like Uncharted Waters 2 / New Horizons, "
    "transparent background.")

# Per-icon object descriptors (identity payload), pinned verbatim;
# amendment = edit here + docs. Pilot batch: the 5 HUD resources + 4
# goods (one per category motif family) + the 4 arrow bases. The
# remaining ~120 fill in after the pilot review freezes the suffix.
_ICON_DESCRIPTORS: dict[str, str] = {
    # --- HUD resources (pilot) ---
    "coin":
        "Round brass coin seen face-on, a simple embossed ship-wheel "
        "stamp in the center, one bright highlight arc on the "
        "upper-left rim, darker bronze shading toward the lower-right",
    "crew":
        "A single sailor's head-and-shoulders bust facing forward, "
        "ruddy warm skin, red knit cap, short dark beard, simple "
        "friendly face",
    "provisions":
        "Stout wooden barrel with two dark iron hoops, a tied "
        "cloth-wrapped bread bundle resting on the flat barrel top",
    "morale":
        "Bright golden fanfare trumpet angled up to the right, small "
        "round bell, tiny spark glints around the bell",
    "durability":
        "Thick grey armor-plate slab with four rivet dots at the "
        "corners and a lighter bevel along the top edge",
    # --- goods pilot (one per category motif family) ---
    "good_wheat":
        "a tied burlap sack of golden wheat grain, two loose wheat "
        "ears leaning against the sack, a few grains scattered in "
        "front of it",
    "good_iron":
        "a neat stack of three dark grey iron ingots, the top ingot "
        "shifted slightly forward, cool blue-grey sheen with one "
        "bright highlight line",
    "good_cotton_cloth":
        "a rolled bolt of pale cream cotton cloth standing upright, "
        "the loose end draping forward with one soft fold",
    "good_spices":
        "a small open wooden bowl heaped with red-orange spice "
        "powder, a tiny wooden scoop resting beside it",
    # --- arrow bases (derivation-only families; only n/ne generate) ---
    "wind_arrow_n":
        "A bold straight arrow pointing straight up to the top edge of "
        "the canvas, thick pale shaft, large triangular head, flat "
        "pale ink fill",
    "wind_arrow_ne":
        "A bold straight arrow pointing to the top-right corner at 45 "
        "degrees, thick pale shaft, large triangular head, flat pale "
        "ink fill",
    "current_arrow_n":
        "A bold straight arrow pointing straight up to the top edge of "
        "the canvas, thick shaft with slightly rounded ends, large "
        "triangular head, flat slate-blue water fill",
    "current_arrow_ne":
        "A bold straight arrow pointing to the top-right corner at 45 "
        "degrees, thick shaft with slightly rounded ends, large "
        "triangular head, flat slate-blue water fill",
    # --- weather/nav (2026-11-08 fleet) ---
    "compass":
        "A round brass ship's compass seen face-on, an eight-point rose "
        "engraved on the pale dial, one red north pointer",
    "calm":
        "A single short pale wind swoosh curling gently to the right "
        "above one small flat wave line, faint and thin",
    "fair":
        "Two moderate pale wind swoosh lines streaming to the right, "
        "one small wave line beneath",
    "strong":
        "Three bold pale wind swoosh lines streaming hard to the right "
        "with small curled ends, a choppy wave line beneath",
    "storm":
        "A dark heavy thundercloud with a bright yellow lightning bolt "
        "beneath it and two thin rain strokes",
    # --- battle (2026-11-08 fleet) ---
    "cannon":
        "A short bronze cannon barrel on a dark wooden carriage with "
        "one small wheel, muzzle pointing right",
    "shot_round":
        "A single heavy black iron cannonball with one white highlight "
        "dot",
    "shot_chain":
        "Two black iron cannonball spheres joined by a short chain "
        "with three links",
    "shot_armor_piercing":
        "A long pointed dark-steel bolt with a wide collar near the "
        "rear and two short fins",
    "shot_grape":
        "A cluster of seven small black iron balls bursting from an "
        "open pale canvas sack",
    "hook":
        "A boarding grappling hook with three curved dark-iron flukes "
        "on a short rope coil",
    "ram":
        "A ship's bow prow rising from a short wave line, a pointed "
        "bronze waterline ram protruding forward at the center",
    "surrender_flag":
        "A plain white rectangular cloth flag on a short wooden pole "
        "tilted left, one soft fold",
    # --- economy/port (2026-11-08 fleet) ---
    "chest":
        "A sturdy wooden treasure chest with dark iron bands and a "
        "brass lock plate, lid closed",
    "scroll":
        "A partially unrolled parchment scroll with two wooden "
        "rollers, warm aged paper",
    "hammer":
        "A shipwright's mallet with a dark iron head and a smooth "
        "wooden handle angled up to the right",
    "bell":
        "A polished brass ship's bell with a dark leather strap and a "
        "small clapper",
    # --- meta/status (2026-11-08 fleet) ---
    "anchor":
        "A classic admiralty anchor with a ring at the top and curved "
        "flukes at the bottom, dark iron",
    "hourglass":
        "A wooden-framed hourglass with pale sand pooling in the "
        "lower bulb",
    "save":
        "A small leather-bound logbook with a brass clasp and a pale "
        "page edge",
    "skull":
        "A white human skull facing forward with dark eye sockets",
    "crown":
        "A golden king's crown with three points and small red gem "
        "studs",
    # --- nation flags (2026-11-08 fleet) ---
    "flag_portugal":
        "A rectangular green cloth flag with a small red roundel at "
        "the center, on a short pole tilted left, one soft wind fold",
    "flag_spain":
        "A rectangular deep-red cloth flag bearing a gold diagonal "
        "cross, on a short pole tilted left, one soft wind fold",
    "flag_england":
        "A rectangular navy-blue cloth flag with a simple red upright "
        "cross, on a short pole tilted left, one soft wind fold",
    "flag_holland":
        "A rectangular flag with three horizontal stripes of red, "
        "white and blue, on a short pole tilted left, one soft wind "
        "fold",
    "flag_ottoman":
        "A rectangular deep-red cloth flag with a white crescent moon "
        "and a small star, on a short pole tilted left, one soft wind "
        "fold",
    "flag_italy":
        "A rectangular flag with three vertical stripes of green, "
        "white and red, on a short pole tilted left, one soft wind "
        "fold",
    "flag_neutral":
        "A plain white rectangular cloth flag with a thin grey "
        "border, on a short pole tilted left, one soft wind fold",
    # --- NPC role badges (2026-11-08 fleet) ---
    "role_trader":
        "A neat stack of two wooden cargo crates bound with dark "
        "straps, a small gold coin resting on top",
    "role_coaster":
        "A small single-mast sailing skiff in flat side view with one "
        "square sail, riding on a short wave line",
    "role_courier":
        "A sealed parchment letter with a red wax seal at the fold",
    "role_patrol":
        "A brass spyglass extended horizontally with a leather grip "
        "band",
    "role_privateer":
        "A curved cutlass blade angled up to the right behind a "
        "sealed parchment with a red wax seal",
    "role_pirate":
        "A black pirate flag with a small white skull marking, on a "
        "short pole tilted left",
    "role_hunter":
        "A bold gold crosshair mark: a ring with four short notch "
        "strokes and a small dot at the center",
    # --- formations (2026-11-08 fleet) ---
    "formation_line_ahead":
        "Four small dark ship silhouettes following one another in a "
        "diagonal line from lower-left to upper-right",
    "formation_column":
        "Four small dark ship silhouettes in a straight vertical "
        "line, bow to stern",
    "formation_screen":
        "Four small dark ship silhouettes spread in a wide horizontal "
        "line abreast",
    "formation_swarm":
        "Six small dark ship silhouettes clustered loosely around the "
        "center at mixed angles",
    # --- trends / trophy (2026-11-08 fleet) ---
    "trend_up":
        "A bold upward-pointing arrow in warm green, thick shaft, "
        "large triangular head",
    "trend_down":
        "A bold downward-pointing arrow in deep red, thick shaft, "
        "large triangular head",
    "event_demand":
        "A bold warm-gold exclamation mark with a square dot",
    "trophy":
        "A golden champion's cup with two curved handles on a small "
        "pedestal, one bright highlight arc",
    # --- remaining goods (2026-11-08 fleet) ---
    "good_olive_oil":
        "a stoneware amphora jug with two small handles and a cork "
        "stopper, pale olive glaze",
    "good_wine":
        "a dark green glass bottle with a long neck and a cork, one "
        "white highlight streak",
    "good_wool":
        "a plump tied bale of creamy white wool with a few loose "
        "curls on top",
    "good_silk":
        "three rolled bolts of shimmering pale-ivory silk stacked "
        "sideways, one loose end draping",
    "good_sugar":
        "a tall white sugar cone wrapped at the bottom in dark blue "
        "paper, standing on a small wooden plate",
    "good_salt":
        "a small wooden bowl heaped with coarse white salt crystals",
    "good_dried_fish":
        "three slim dried fish tied together at the tails, hanging "
        "tail-up, pale grey-brown",
    "good_timber":
        "a neat stack of four cut logs with pale sawn ends, bark "
        "still on",
    "good_copper":
        "a neat stack of three reddish-copper ingots with one bright "
        "highlight line",
    "good_glassware":
        "two pale blue-green glass goblets, one nested inside the "
        "other, thin bright rims",
    "good_leather":
        "a tightly rolled brown hide with a leather tie, one curled "
        "loose edge",
    "good_ceramics":
        "a stack of two glazed blue-and-white bowls with a covered "
        "jar beside them",
    "good_perfume":
        "a small elegant glass flask with a slender neck and a round "
        "stopper, pale rose liquid inside",
    "good_carpet":
        "a rolled red carpet with a gold pattern band visible at the "
        "open end, tied with a cord",
    "good_amber":
        "a rounded lump of warm golden amber with one bright "
        "highlight facet",
    "good_cheese":
        "a whole pale-yellow cheese wheel with one wedge cut out, "
        "the wedge leaning against it",
    "good_rice":
        "an open burlap sack heaped with white rice grains, a few "
        "spilled in front",
    "good_pitch":
        "a small wooden barrel with thick black tar dripping over "
        "one hoop",
    "good_linen":
        "a neat folded stack of pale cream linen cloth, three "
        "layers",
    "good_furs":
        "a stack of two brown fur pelts with tails visible, soft "
        "shaggy edges",
    "good_dye_wood":
        "two short log sections split open showing deep red "
        "heartwood",
    "good_indigo":
        "a stack of three deep-blue rectangular dye cakes with a "
        "lighter blue dusting",
    "good_ivory":
        "a single curved white ivory tusk with a polished tip, "
        "lying at a slight angle",
    "good_sandalwood":
        "two short log sections split open showing rich red-brown "
        "heartwood",
    "good_coffee":
        "an open burlap sack heaped with dark brown coffee beans, a "
        "few spilled in front",
    "good_tobacco":
        "a bundle of broad dried brown leaves tied with a cord at "
        "the stems",
    "good_tea":
        "a small lidded ceramic tea jar in pale green glaze",
    "good_rhubarb":
        "a bundle of dried brownish rhubarb roots tied with cord, "
        "fine root threads visible",
    "good_raw_silk":
        "two loose skeins of pale ivory silk thread stacked, one "
        "strand looping free",
    "good_porcelain":
        "a single white porcelain vase with a blue painted band and "
        "a flared lip",
    "good_pearls":
        "an open grey oyster shell holding three round white pearls",
    "good_gems":
        "a small pile of four cut gemstones in red, green and blue, "
        "faceted tops catching the light",
    "good_musk":
        "a small round brown scent pouch tied at the neck with a "
        "cord tassel",
    "good_lacquerware":
        "a black lacquered box with a gold painted rim, lid slightly "
        "ajar",
    "good_silver":
        "a neat stack of three bright silver ingots with one "
        "highlight line",
    "good_gold":
        "a small pile of gold coins beside two stacked gold ingots, "
        "bright yellow",
    # --- equipment (2026-11-08 fleet; en names ride the composer) ---
    "eq_cutlass":
        "a curved single-edged cutlass blade with a simple curved "
        "guard, angled up to the right",
    "eq_rapier":
        "a slender straight rapier blade with an ornate round guard, "
        "angled up to the right",
    "eq_backsword":
        "a single-edged straight backsword with a knuckle guard, "
        "angled up to the right",
    "eq_main_gauche":
        "a short slim parrying dagger with a wide guard, angled up "
        "to the right",
    "eq_zweihander":
        "a very large two-handed greatsword with a long double blade "
        "and a wide crossguard, angled up to the right",
    "eq_khair_scimitar":
        "a deeply curved scimitar blade with a flared tip, angled up "
        "to the right",
    "eq_breastplate":
        "a rounded steel breastplate seen from the front, a central "
        "ridge and two shoulder plates",
    "eq_lucky_charm":
        "a small golden four-leaf clover pendant hanging from a "
        "short cord",
    "eq_brigandine":
        "a leather-and-steel brigandine torso front with two rows of "
        "exposed steel rivet studs",
    "eq_saint_medallion":
        "a round silver medallion on a short chain, a simple engraved "
        "cross at the center",
    "eq_three_quarter_armor":
        "an upper-body steel armor: breastplate with two shoulder "
        "pauldrons and a visored helm above",
    "eq_bloodhand_cuirass":
        "a dark red-lacquered cuirass with a black hand emblem on "
        "the chest",
    "eq_mermaid_figurehead":
        "a carved wooden mermaid figurehead bust with flowing hair "
        "and a scaled tail",
    "eq_eagle_figurehead":
        "a carved wooden eagle head figurehead with a hooked golden "
        "beak",
    "eq_dragon_figurehead":
        "a carved wooden dragon head figurehead with an open jaw and "
        "small horns",
    "eq_albatross_figurehead":
        "a carved white albatross figurehead with spread wings and a "
        "pale beak",
    "eq_angel_figurehead":
        "a carved pale angel figurehead bust with folded wings and a "
        "gold halo",
    "eq_golden_dragon_figurehead":
        "a gilded golden dragon head figurehead with an open jaw and "
        "spread wings",
    "eq_cotton_sails":
        "a folded square sail of plain pale cotton cloth with two "
        "horizontal seam bands",
    "eq_matting_sails":
        "a folded sail of coarse woven mat fiber with a visible "
        "basket-weave pattern",
    "eq_storm_sails":
        "a small tightly folded storm sail of heavy dark-grey canvas "
        "with reinforcing bands",
    "eq_flemish_linen_sails":
        "a folded sail of fine cream linen with a fine vertical weave "
        "and a pale sheen",
    "eq_brocade_sails":
        "a folded sail of rich red brocade cloth with a gold pattern "
        "band along the edge",
    "eq_red_sail":
        "a folded sail of deep crimson-red cloth with a darker red "
        "border band",
}
# Full-variant replacements (whole description; none yet — the pinnace
# precedent).
_ICON_VARIANTS: dict[str, str] = {}


# ---- glyph pass pins (80-* §4.8, the 2026-11-08 marker/facility
# amendment) --------------------------------------------------------------
# The 6 markers + 6 facility tokens join the PixelLab backend under the
# ICON ruling: prompt-only generate-image-v2 at 64x64 (seed 92000, the
# icon envelope), quantize-to-owning-block + 2:1 halve at INGEST. Two
# REWRITTEN suffixes — no icon heritage (user direction).
GLYPH_OUT_DIR = os.path.join(REPO, "tools", "ui_art", "model_raw",
                             "pixellab_glyphs")
GLYPH_MANIFEST = os.path.join(GLYPH_OUT_DIR, "pixellab_glyphs.json")
# MARKER_SUFFIX, pinned verbatim (80-* §4.8 2026-11-08; the map-overlay
# design problem is separation over live sea AND land tiles, not palette
# discipline).
MARKER_SUFFIX = (
    ", single centered world-map marker glyph, bold compact silhouette "
    "readable at tiny size, thick dark 1-pixel outline, flat cel shading "
    "with two or three shading bands, strong contrast against both blue "
    "sea and brown land, single object fully inside the frame, no "
    "scenery, no text, no gradients, retro 16-bit pixel-art game map "
    "marker in the style of classic 1990s naval adventure games like "
    "Uncharted Waters 2 / New Horizons, transparent background.")
# FACILITY_SUFFIX, pinned verbatim (80-* §4.8 2026-11-08; building fronts
# are a different object class from every prior family; signs stay
# UNLETTERED).
FACILITY_SUFFIX = (
    ", small 16th-century European port building front seen straight-on, "
    "flat frontal facade, centered doorway, one or two windows, thick "
    "dark 1-pixel outline, warm wood and stone midtones, bold readable "
    "silhouette, flat cel shading with two or three shading bands, the "
    "building fully inside the frame, no scenery around it, no text, no "
    "lettered signs, no gradients, retro 16-bit pixel-art in the style "
    "of classic 1990s naval adventure games like Uncharted Waters 2 / "
    "New Horizons, transparent background.")

# Per-glyph identity+spec descriptors, pinned verbatim (80-* §4.8
# 2026-11-08); amendment = edit here + docs. Composition =
# {descriptor}{<family suffix>} — the identity rides the descriptor.
_GLYPH_DESCRIPTORS: dict[str, str] = {
    # --- world-map markers ---
    "marker_treasure":
        "A golden X-shaped treasure cross mark with a slight sheen",
    "marker_wreck":
        "A broken sunken ship hull floating bow-down with exposed ribs "
        "and a tilted mast stump",
    "marker_discovery_creature":
        "A friendly finned sea-creature silhouette breaching a small "
        "wave",
    "marker_discovery_natural":
        "A small rocky island with one tall palm tree",
    "marker_discovery_relic":
        "A leaning carved stone relic head half-buried in a small "
        "mound",
    "marker_discovery_ruins":
        "Two broken mossy stone columns on a cracked slab",
    # --- port facility tokens ---
    "facility_market":
        "A market stall building with a striped awning over goods "
        "crates",
    "facility_shipyard":
        "A timber shipyard slipway shed with a hoist crane arm",
    "facility_palace":
        "A grand two-floor palace facade with columns and a triangular "
        "pediment",
    "facility_tavern":
        "A low timber tavern front with a hanging tankard sign",
    "facility_inn":
        "A cozy inn front with a hanging lantern sign",
    "facility_guild":
        "A guild hall front with a hanging banner",
}


def _glyph_desc(glyph_id: str) -> str:
    """Composed description: {identity+spec}{family suffix} (80-* §4.8
    2026-11-08)."""
    if glyph_id not in _GLYPH_DESCRIPTORS:
        raise SystemExit(
            f"{glyph_id}: no pinned descriptor in _GLYPH_DESCRIPTORS — "
            f"the doc-first rule forbids sending an unpinned prompt")
    suffix = (FACILITY_SUFFIX if glyph_id.startswith("facility_")
              else MARKER_SUFFIX)
    return f"{_GLYPH_DESCRIPTORS[glyph_id]}{suffix}"


def _glyphs() -> list[str]:
    """The 12-id glyph inventory, read from the authored manifests (the
    marker + facility string-map files stay the id authority)."""
    import glob  # noqa: PLC0415
    ids: list[str] = []
    for path in (sorted(glob.glob(os.path.join(REPO, "tools", "ui_art",
                                               "markers", "*.json")))
                 + sorted(glob.glob(os.path.join(REPO, "tools", "ui_art",
                                                 "hulls", "facility_*.json")))):
        with open(path, encoding="utf-8") as fh:
            doc = json.load(fh)
        items = doc if isinstance(doc, list) else doc.get("sprites", [doc])
        for s in items:
            if isinstance(s, dict) and s.get("id"):
                ids.append(str(s["id"]))
    return ids


def run_glyph(glyph_id: str, label: str | None = None,
              description: str | None = None, seed: int | None = None,
              poll_status=None) -> dict:
    """One prompt-only generate-image-v2 generation on the pinned 64x64
    canvas (the icon envelope — never a style_image or reference_images)
    + raw download to <id>/icon.png."""
    payload = {
        "description": description or _glyph_desc(glyph_id),
        "image_size": {"width": ICON_SIZE, "height": ICON_SIZE},
        "no_background": True,
        "seed": ICON_SEED if seed is None else int(seed),
    }
    print(f"[pixellab-glyphs {glyph_id}] POST generate-image-v2 "
          f"({ICON_SIZE}x{ICON_SIZE}) ...", flush=True)
    created = _post("/generate-image-v2", payload)
    job_id = created["background_job_id"]
    usage = created.get("usage") or {}
    print(f"    job={job_id} usage={json.dumps(usage)}", flush=True)

    deadline = time.time() + POLL_MAX
    job = {}
    while time.time() < deadline:
        time.sleep(POLL_S)
        job = _get(f"/background-jobs/{job_id}")
        if poll_status is not None:
            try:
                poll_status(str(job.get("status")))
            except Exception:  # noqa: BLE001 — the ticker must never kill a job
                pass
        if job.get("status") in ("completed", "failed"):
            break
        print(f"    status={job.get('status')}", flush=True)
    if job.get("status") != "completed":
        raise RuntimeError(f"{glyph_id}: job {job_id} status="
                           f"{job.get('status')!r} "
                           f"(last: {json.dumps(job)[:300]})")

    dest = label or glyph_id
    dest_dir = os.path.join(GLYPH_OUT_DIR, dest)
    os.makedirs(dest_dir, exist_ok=True)
    png = _job_image_bytes(job)
    with open(os.path.join(dest_dir, "icon.png"), "wb") as fh:
        fh.write(png)
    rec = {"job_id": job_id, "description": payload["description"],
           "seed": payload["seed"], "size": ICON_SIZE, "glyph": glyph_id,
           "label": dest, "bytes": {"icon": len(png)},
           "usage": usage, "job_status": job.get("status")}
    os.makedirs(GLYPH_OUT_DIR, exist_ok=True)
    # merge-retry write (multi-worker safe — the icon-pass precedent)
    for attempt in range(4):
        manifest = {}
        if os.path.isfile(GLYPH_MANIFEST):
            try:
                with open(GLYPH_MANIFEST, encoding="utf-8") as fh:
                    manifest = json.load(fh)
                break
            except ValueError:
                time.sleep(0.5 * (attempt + 1))
        else:
            break
    manifest[dest] = rec
    with open(GLYPH_MANIFEST, "w", encoding="utf-8") as fh:
        json.dump(manifest, fh, indent=1, ensure_ascii=False)
    return rec


def snap_glyph(glyph_id: str) -> None:
    """Glyph-as-drawn passthrough into <id>/snapped/icon.png. Gate:
    canvas fit (exact 64x64); quantize + halve happen at ingest."""
    from PIL import Image  # noqa: PLC0415
    src_dir = os.path.join(GLYPH_OUT_DIR, glyph_id)
    src = os.path.join(src_dir, "icon.png")
    if not os.path.exists(src):
        raise SystemExit(f"{glyph_id}: no raw glyph at {src} — "
                         f"run --glyphs run first")
    img = Image.open(src)
    w, h = img.size
    fit = (w, h) == (ICON_SIZE, ICON_SIZE)
    dst_dir = os.path.join(src_dir, "snapped")
    os.makedirs(dst_dir, exist_ok=True)
    with open(src, "rb") as fh:
        data = fh.read()
    with open(os.path.join(dst_dir, "icon.png"), "wb") as fh:
        fh.write(data)
    print(f"  {glyph_id}: raw copy {w}x{h} want={ICON_SIZE}x{ICON_SIZE} "
          f"fit={fit}", flush=True)


def run_glyph_fleet(ids: list[str], seed: int | None = None) -> None:
    todo = [i for i in ids if i in _GLYPH_DESCRIPTORS]
    skipped = len(ids) - len(todo)
    if skipped:
        print(f"[pixellab-glyphs] {skipped} id(s) without a pinned "
              f"descriptor — not sent to the API", flush=True)
    for i, glyph_id in enumerate(todo, 1):
        raw = os.path.join(GLYPH_OUT_DIR, glyph_id, "icon.png")
        if os.path.isfile(raw):
            print(f"[pixellab-glyphs {i}/{len(todo)}] {glyph_id} already "
                  f"has raw icon.png — skipped (delete it to re-roll)",
                  flush=True)
            continue
        rec = run_glyph(glyph_id, seed=seed)
        print(f"[pixellab-glyphs {i}/{len(todo)}] {glyph_id} saved "
              f"icon.png ({rec['bytes']['icon']} bytes)", flush=True)
    print(f"[pixellab-glyphs] manifest -> {GLYPH_MANIFEST}", flush=True)


def status_glyphs() -> None:
    if not os.path.exists(GLYPH_MANIFEST):
        print("no glyph manifest yet")
        return
    with open(GLYPH_MANIFEST, encoding="utf-8") as fh:
        m = json.load(fh)
    for glyph_id, e in m.items():
        print(f"{glyph_id:28s} size={e['size']} seed={e['seed']} "
              f"job={e['job_id'][:12]}…")
    print(f"{len(m)} glyphs")


def _good_en_name(good_id: str) -> str:
    with open(os.path.join(REPO, "data", "goods.json"),
              encoding="utf-8") as fh:
        goods = {g["id"]: g for g in json.load(fh)["goods"]}
    return str(goods[good_id]["name"]["en"])


def _eq_en_name(eq_id: str) -> str:
    with open(os.path.join(REPO, "data", "equipment.json"),
              encoding="utf-8") as fh:
        eqs = {e["id"]: e for e in json.load(fh)["equipment"]}
    return str(eqs[eq_id]["name"]["en"])


def _icon_desc(icon_id: str) -> str:
    """Composed description: {Name-en}, {object spec}{ICON_SUFFIX} for
    goods/equipment; {object spec}{ICON_SUFFIX} for pure glyphs; a
    full-variant replacement wins outright (80-* §4.8 2026-11-08)."""
    if icon_id in _ICON_VARIANTS:
        return _ICON_VARIANTS[icon_id]
    if icon_id not in _ICON_DESCRIPTORS:
        raise SystemExit(
            f"{icon_id}: no pinned descriptor in _ICON_DESCRIPTORS — "
            f"the doc-first rule forbids sending an unpinned prompt")
    base = _ICON_DESCRIPTORS[icon_id]
    if icon_id.startswith("good_"):
        return f"{_good_en_name(icon_id[5:])}, {base}{ICON_SUFFIX}"
    if icon_id.startswith("eq_"):
        # equipment data ids carry the eq_ prefix themselves (unlike
        # goods) — no strip
        return f"{_eq_en_name(icon_id)}, {base}{ICON_SUFFIX}"
    return f"{base}{ICON_SUFFIX}"


def _icons() -> list[str]:
    """The full 129-id inventory, read from the authored manifests (the
    committed string-map files stay the id authority)."""
    import glob  # noqa: PLC0415
    ids: list[str] = []
    for path in sorted(glob.glob(os.path.join(REPO, "tools", "ui_art",
                                              "icons", "*.json"))):
        with open(path, encoding="utf-8") as fh:
            ids.extend(s["id"] for s in json.load(fh)["sprites"])
    return ids


def run_icon(icon_id: str, label: str | None = None,
             description: str | None = None, seed: int | None = None,
             poll_status=None) -> dict:
    """One prompt-only generate-image-v2 generation on the pinned 64x64
    canvas (the 2026-11-08 icon envelope — never a style_image or
    reference_images) + raw download to <id>/icon.png."""
    payload = {
        "description": description or _icon_desc(icon_id),
        "image_size": {"width": ICON_SIZE, "height": ICON_SIZE},
        "no_background": True,
        "seed": ICON_SEED if seed is None else int(seed),
    }
    print(f"[pixellab-icons {icon_id}] POST generate-image-v2 "
          f"({ICON_SIZE}x{ICON_SIZE}) ...", flush=True)
    created = _post("/generate-image-v2", payload)
    job_id = created["background_job_id"]
    usage = created.get("usage") or {}
    print(f"    job={job_id} usage={json.dumps(usage)}", flush=True)

    deadline = time.time() + POLL_MAX
    job = {}
    while time.time() < deadline:
        time.sleep(POLL_S)
        job = _get(f"/background-jobs/{job_id}")
        if poll_status is not None:
            try:
                poll_status(str(job.get("status")))
            except Exception:  # noqa: BLE001 — the ticker must never kill a job
                pass
        if job.get("status") in ("completed", "failed"):
            break
        print(f"    status={job.get('status')}", flush=True)
    if job.get("status") != "completed":
        raise RuntimeError(f"{icon_id}: job {job_id} status="
                           f"{job.get('status')!r} "
                           f"(last: {json.dumps(job)[:300]})")

    dest = label or icon_id
    dest_dir = os.path.join(ICON_OUT_DIR, dest)
    os.makedirs(dest_dir, exist_ok=True)
    png = _job_image_bytes(job)
    with open(os.path.join(dest_dir, "icon.png"), "wb") as fh:
        fh.write(png)
    rec = {"job_id": job_id, "description": payload["description"],
           "seed": payload["seed"], "size": ICON_SIZE, "icon": icon_id,
           "label": dest, "bytes": {"icon": len(png)},
           "usage": usage, "job_status": job.get("status")}
    os.makedirs(ICON_OUT_DIR, exist_ok=True)
    # Merge-retry write (multi-worker safe): parallel --icons workers
    # finish jobs independently; each write re-reads the latest manifest
    # so a sibling's record survives (last-writer-wins on the SAME id is
    # impossible — slices are disjoint per worker).
    for attempt in range(4):
        manifest = {}
        if os.path.isfile(ICON_MANIFEST):
            try:
                with open(ICON_MANIFEST, encoding="utf-8") as fh:
                    manifest = json.load(fh)
                break
            except ValueError:
                time.sleep(0.5 * (attempt + 1))
        else:
            break
    manifest[dest] = rec
    with open(ICON_MANIFEST, "w", encoding="utf-8") as fh:
        json.dump(manifest, fh, indent=1, ensure_ascii=False)
    return rec


def snap_icon(icon_id: str) -> None:
    """Icon-as-drawn passthrough: the RAW icon copies BYTE-IDENTICAL
    into <id>/snapped/icon.png for ingest naming. Gate: canvas fit
    (exact 64x64). No resize, no quantize — the model's pixels are the
    review pixels; quantize + halve happen at ingest (80-* §4.8
    2026-11-08)."""
    from PIL import Image  # noqa: PLC0415
    src_dir = os.path.join(ICON_OUT_DIR, icon_id)
    src = os.path.join(src_dir, "icon.png")
    if not os.path.exists(src):
        raise SystemExit(f"{icon_id}: no raw icon at {src} — "
                         f"run --icons run first")
    img = Image.open(src)
    w, h = img.size
    fit = (w, h) == (ICON_SIZE, ICON_SIZE)
    dst_dir = os.path.join(src_dir, "snapped")
    os.makedirs(dst_dir, exist_ok=True)
    with open(src, "rb") as fh:
        data = fh.read()
    with open(os.path.join(dst_dir, "icon.png"), "wb") as fh:
        fh.write(data)
    print(f"  {icon_id}: raw copy {w}x{h} want={ICON_SIZE}x{ICON_SIZE} "
          f"fit={fit}", flush=True)


def run_icon_fleet(ids: list[str], seed: int | None = None) -> None:
    # The doc-first guard applies per id: derived-only arrow dirs and any
    # id without a pinned descriptor are never generated.
    todo = [i for i in ids
            if i in _ICON_DESCRIPTORS or i in _ICON_VARIANTS]
    skipped = len(ids) - len(todo)
    if skipped:
        print(f"[pixellab-icons] {skipped} id(s) without a pinned "
              f"descriptor or derivation-only — not sent to the API",
              flush=True)
    for i, icon_id in enumerate(todo, 1):
        raw = os.path.join(ICON_OUT_DIR, icon_id, "icon.png")
        if os.path.isfile(raw):
            # resumable: the raw file IS the artifact — a re-roll deletes
            # it (or names the id explicitly on the CLI)
            print(f"[pixellab-icons {i}/{len(ids)}] {icon_id} already has "
                  f"raw icon.png — skipped (delete it to re-roll)",
                  flush=True)
            continue
        rec = run_icon(icon_id, seed=seed)
        print(f"[pixellab-icons {i}/{len(ids)}] {icon_id} saved "
              f"icon.png ({rec['bytes']['icon']} bytes)", flush=True)
    print(f"[pixellab-icons] manifest -> {ICON_MANIFEST}", flush=True)


def status_icons() -> None:
    if not os.path.exists(ICON_MANIFEST):
        print("no icon manifest yet")
        return
    with open(ICON_MANIFEST, encoding="utf-8") as fh:
        m = json.load(fh)
    for icon_id, e in m.items():
        print(f"{icon_id:24s} size={e['size']} seed={e['seed']} "
              f"job={e['job_id'][:12]}…")
    print(f"{len(m)} icons")


def _ships() -> list[str]:
    with open(os.path.join(REPO, "data", "ship_types.json"),
              encoding="utf-8") as fh:
        return [s["id"] for s in json.load(fh)["ship_types"]]


def _key() -> str:
    """API key: env PIXELLAB_API_KEY wins; else the gitignored config
    tools/pixellab_config.json ({"api_key": "..."}), so any agent or
    process in this repo picks the key up without env setup."""
    k = os.environ.get("PIXELLAB_API_KEY")
    if k:
        return k
    cfg = os.path.join(REPO, "tools", "pixellab_config.json")
    if os.path.exists(cfg):
        with open(cfg, encoding="utf-8") as fh:
            k = json.load(fh).get("api_key")
        if k:
            return k
    raise SystemExit("PIXELLAB_API_KEY not set and no "
                     "tools/pixellab_config.json")


def _post(path: str, payload: dict) -> dict:
    req = urllib.request.Request(
        f"{API}{path}", data=json.dumps(payload).encode("utf-8"),
        headers={"Authorization": f"Bearer {_key()}",
                 "Content-Type": "application/json"}, method="POST")
    with urllib.request.urlopen(req, timeout=120) as resp:
        return json.loads(resp.read())


def _get(path: str, binary: bool = False):
    req = urllib.request.Request(
        f"{API}{path}", headers={"Authorization": f"Bearer {_key()}"})
    with urllib.request.urlopen(req, timeout=120) as resp:
        raw = resp.read()
    return raw if binary else json.loads(raw)


def _save_spritesheet(object_id: str, dest_dir: str) -> dict:
    """Cut the 8 rotations out of the object spritesheet ZIP (the
    rotation_urls presigned links 403 after expiry)."""
    import io  # noqa: PLC0415
    import zipfile  # noqa: PLC0415
    from PIL import Image  # noqa: PLC0415
    raw = _get(f"/objects/{object_id}/spritesheet", binary=True)
    zf = zipfile.ZipFile(io.BytesIO(raw))
    layout = json.loads(zf.read([n for n in zf.namelist()
                                 if n.endswith(".json")][0]))
    sheet_png = [n for n in zf.namelist() if n.endswith(".png")][0]
    sheet = Image.open(io.BytesIO(zf.read(sheet_png))).convert("RGBA")
    sp = layout["spritesheet"]
    cw, ch = sp["cell_size"]["width"], sp["cell_size"]["height"]
    order = []
    for row in sp["rows"]:
        order.extend(row["directions"])
    saved = {}
    for i, dir_name in enumerate(order):
        cx, cy = (i % sp["columns"]) * cw, (i // sp["columns"]) * ch
        cell = sheet.crop((cx, cy, cx + cw, cy + ch))
        buf = io.BytesIO()
        cell.save(buf, "PNG")
        png = buf.getvalue()
        with open(os.path.join(dest_dir, f"{dir_name}.png"), "wb") as fh:
            fh.write(png)
        saved[dir_name] = len(png)
    return saved


def _save_rotations(urls: dict, dest_dir: str) -> dict:
    saved = {}
    for dir_name in DIRS:
        url = urls.get(dir_name)
        if not url:
            raise RuntimeError(f"no rotation url for {dir_name}: "
                               f"{sorted(urls)}")
        png = _download(url)
        with open(os.path.join(dest_dir, f"{dir_name}.png"), "wb") as fh:
            fh.write(png)
        saved[dir_name] = len(png)
    return saved


# The coastline tileset envelope — verbatim from the vendored request
# (tools/assets/pixellab_raw/tileset_coastline_77f5cd00-…_request.json,
# the accepted 2026-11-06 generation). Re-rolls may override the three
# descriptions and the seeds; everything else stays pinned.
COAST_DEFAULT_REQUEST = {
    "lower_description": "calm shallow coastal sea, muted slate blue, "
                         "semi-flat painterly water with sparse 2-3 pixel "
                         "ripple dabs, 16-bit retro world map ocean tile in "
                         "the style of Uncharted Waters 2, no wave crests, "
                         "no foam",
    "upper_description": "dry earth-brown coastal land, warm ochre shoreline "
                         "rising to darker umber ground, Mediterranean "
                         "16th-century coastline, 16-bit retro world map "
                         "land tile in the style of Uncharted Waters 2",
    "transition_description": "narrow wet sand beach with a thin broken "
                              "foam line, Uncharted Waters 2 style shoreline "
                              "transition",
    "mode": "pro",
    "tile_size": {"width": 64, "height": 64},
    "view": "high top-down",
    "transition_size": 0.25,
    "roundness": 1,
    "raggedness": 0.35,
    "boundary_amplitude": 0.15,
    "boundary_seed": 42,
    "detail": "highly detailed",
}
COAST_DEFAULT_SEED = 20261106


def run_coast_tileset(seed: int | None = None, lower: str | None = None,
                      upper: str | None = None, transition: str | None = None,
                      boundary_seed: int | None = None,
                      poll_status=None) -> dict:
    """One /create-tileset generation (pro corner mode) + raw download.
    The studio (tools/model_studio) calls this in-process; payload shape is
    the accepted vendored request, descriptions/seed overridable."""
    payload = dict(COAST_DEFAULT_REQUEST)
    if lower:
        payload["lower_description"] = lower
    if upper:
        payload["upper_description"] = upper
    if transition:
        payload["transition_description"] = transition
    payload["seed"] = COAST_DEFAULT_SEED if seed is None else int(seed)
    if boundary_seed is not None:
        payload["boundary_seed"] = int(boundary_seed)
    print("[pixellab coast] POST /create-tileset ...", flush=True)
    created = _post("/create-tileset", payload)
    job_id, tileset_id = (created["background_job_id"],
                          created["tileset_id"])
    print(f"    job={job_id} tileset={tileset_id}", flush=True)

    deadline = time.time() + POLL_MAX
    job = {}
    while time.time() < deadline:
        time.sleep(POLL_S)
        job = _get(f"/background-jobs/{job_id}")
        if poll_status is not None:
            try:
                poll_status(str(job.get("status")))
            except Exception:  # noqa: BLE001 — the ticker must never kill a job
                pass
        if job.get("status") in ("completed", "failed"):
            break
        print(f"    status={job.get('status')}", flush=True)
    if job.get("status") != "completed":
        raise RuntimeError(f"coast tileset: job {job_id} status="
                           f"{job.get('status')!r} (last: {json.dumps(job)[:300]})")
    result = _get(f"/tilesets/{tileset_id}")
    tiles = result.get("tileset", {}).get("tiles", [])
    print(f"    tileset {tileset_id}: {len(tiles)} tiles", flush=True)
    return {"tileset_id": tileset_id, "job_id": job_id,
            "seed": payload["seed"], "payload": payload,
            "result": result}


def run_ship(ship: str, label: str | None = None, description: str | None = None,
             seed: int | None = None, poll_status=None) -> dict:
    """One create-object-pro-flash generation + raw download. The studio
    (tools/model_studio) calls this in-process with an explicit
    description (free text, the user's edit) + seed; the CLI keeps the
    pinned defaults. poll_status, when given, receives each background
    job status string for the studio's stage ticker. The envelope stays
    exactly the pinned 5 fields — no style_image, ever (80-* §4.8)."""
    payload = {
        "description": description or _desc(ship),
        "name": ship,
        "image_size": {"width": 64, "height": 64},
        "n_directions": 8,
        "view": VIEW,
        "seed": 91000 if seed is None else int(seed),
    }
    print(f"[pixellab {ship}] POST create-object-pro-flash ...", flush=True)
    created = _post("/create-object-pro-flash", payload)
    job_id, object_id = created["background_job_id"], created["object_id"]
    usage = created.get("usage") or {}
    print(f"    job={job_id} object={object_id} "
          f"usage={json.dumps(usage)}", flush=True)

    deadline = time.time() + POLL_MAX
    job = {}
    while time.time() < deadline:
        time.sleep(POLL_S)
        job = _get(f"/background-jobs/{job_id}")
        if poll_status is not None:
            try:
                poll_status(str(job.get("status")))
            except Exception:  # noqa: BLE001 — the ticker must never kill a job
                pass
        if job.get("status") in ("completed", "failed"):
            break
        print(f"    status={job.get('status')}", flush=True)
    if job.get("status") != "completed":
        raise RuntimeError(f"{ship}: job {job_id} status="
                           f"{job.get('status')!r} (last: {json.dumps(job)[:300]})")

    dest = label or ship
    dest_dir = os.path.join(OUT_DIR, dest)
    os.makedirs(dest_dir, exist_ok=True)
    obj = _get(f"/objects/{object_id}")
    try:
        saved = _save_rotations(obj["rotation_urls"], dest_dir)
    except (urllib.error.HTTPError, RuntimeError) as e:
        print(f"    rotation_urls failed ({e}); spritesheet fallback",
              flush=True)
        saved = _save_spritesheet(object_id, dest_dir)
    rec = {"object_id": object_id, "job_id": job_id,
           "description": payload["description"], "seed": payload["seed"],
           "view": payload["view"], "bytes": saved,
           "job_status": job.get("status"),
           "ship": ship, "label": dest,
           "object_response": obj}
    return rec


def _download(url: str) -> bytes:
    """Rotation URLs 403 without auth on some accounts — retry with the
    bearer header before giving up."""
    try:
        with urllib.request.urlopen(url, timeout=120) as resp:
            return resp.read()
    except urllib.error.HTTPError as e:
        if e.code != 403:
            raise
    key = _key()
    req = urllib.request.Request(url, headers={"Authorization": f"Bearer {key}"})
    with urllib.request.urlopen(req, timeout=120) as resp:
        return resp.read()


def fetch_ship(ship: str, object_id: str | None = None) -> dict:
    """Re-download a completed object's 8 rotations (no new generation).
    Tries the stored rotation_urls (auth-retried), falls back to the
    spritesheet ZIP + layout JSON. Bootstraps the manifest entry from the
    object API when a previous run died before persisting it."""
    try:
        with open(MANIFEST, encoding="utf-8") as fh:
            manifest = json.load(fh)
    except FileNotFoundError:
        manifest = {}
    rec = manifest.get(ship) or {"object_id": object_id}
    object_id = rec["object_id"]
    if object_id is None:
        raise SystemExit(f"{ship}: no manifest entry and no object_id arg")
    obj = _get(f"/objects/{object_id}")
    rec.setdefault("object_id", object_id)
    rec.setdefault("description", obj.get("prompt"))
    rec.setdefault("view", obj.get("view"))
    rec["object_response"] = obj
    urls = obj.get("rotation_urls") or rec.get("rotation_urls") or {}
    dest_dir = os.path.join(OUT_DIR, ship)
    os.makedirs(dest_dir, exist_ok=True)
    saved = {}
    try:
        if not urls:
            raise RuntimeError("no rotation urls")
        for dir_name in DIRS:
            url = urls.get(dir_name)
            if not url:
                raise RuntimeError(f"{ship}: no rotation url for {dir_name}")
            png = _download(url)
            with open(os.path.join(dest_dir, f"{dir_name}.png"), "wb") as fh:
                fh.write(png)
            saved[dir_name] = len(png)
    except (urllib.error.HTTPError, RuntimeError) as e:
        print(f"    rotation_urls failed ({e}); spritesheet fallback",
              flush=True)
        saved = {}
        raw = _get(f"/objects/{object_id}/spritesheet", binary=True)
        import io  # noqa: PLC0415
        import zipfile  # noqa: PLC0415
        zf = zipfile.ZipFile(io.BytesIO(raw))
        layout = json.loads(zf.read([n for n in zf.namelist()
                                     if n.endswith(".json")][0]))
        sheet_png = [n for n in zf.namelist() if n.endswith(".png")][0]
        from PIL import Image  # noqa: PLC0415
        sheet = Image.open(io.BytesIO(zf.read(sheet_png))).convert("RGBA")
        # layout: spritesheet.cell_size (w/h), columns, rows[].directions
        # (dir name per column, left to right) — cut each 64x64 cell.
        sp = layout["spritesheet"]
        cw, ch = sp["cell_size"]["width"], sp["cell_size"]["height"]
        order = []
        for row in sp["rows"]:
            order.extend(row["directions"])
        for i, dir_name in enumerate(order):
            cx, cy = (i % sp["columns"]) * cw, (i // sp["columns"]) * ch
            cell = sheet.crop((cx, cy, cx + cw, cy + ch))
            buf = io.BytesIO()
            cell.save(buf, "PNG")
            png = buf.getvalue()
            with open(os.path.join(dest_dir, f"{dir_name}.png"), "wb") as fh:
                fh.write(png)
            saved[dir_name] = len(png)
        rec["spritesheet_fallback"] = True
    rec["bytes"] = saved
    manifest[ship] = rec
    with open(MANIFEST, "w", encoding="utf-8") as fh:
        json.dump(manifest, fh, indent=1, ensure_ascii=False)
    print(f"[pixellab fetch] {ship}: {len(saved)} dirs saved "
          f"(object {object_id})", flush=True)
    return rec


# ---- snap (ship-as-drawn, user direction 2026-11-06): NO pixel edits.
# The earlier pennant-only recolor (option B) was rejected by the user —
# flattening the flag's shading looked terrible. The raw rotations copy
# byte-identical into snapped/ (dir-id names for ingest); the SAME token
# ships for every owner (the ×7 pennant remap is suspended for this
# family). Gates: canvas fit only.
DIR_MAP = {  # pixellab rotation name -> our heading8 dir id
    "north": "n", "north-east": "ne", "north-west": "nw",
    "south": "s", "south-east": "se", "south-west": "sw",
    "east": "e", "west": "w",
}


def snap_ship(ship: str) -> None:
    """Ship-as-drawn passthrough (user direction 2026-11-06, supersedes
    the pennant recolor — 'the flag you modified are terrible'): the RAW
    PixelLab rotations copy BYTE-IDENTICAL into
    <ship>/snapped/<dir_id>.png for the ingest naming. No pennant
    recolor, no resize, no quantize — the model's pixels are the shipped
    pixels, the same token for every owner. Gate: canvas fit only."""
    from PIL import Image  # noqa: PLC0415
    src_dir = os.path.join(OUT_DIR, ship)
    dst_dir = os.path.join(src_dir, "snapped")
    os.makedirs(dst_dir, exist_ok=True)
    for rot, dir_id in DIR_MAP.items():
        path = os.path.join(src_dir, f"{rot}.png")
        if not os.path.exists(path):
            continue
        img = Image.open(path)
        w, h = img.size
        fit = 0 <= w <= 64 and 0 <= h <= 64
        # byte-identical copy: the raw file IS the token
        dst = os.path.join(dst_dir, f"{dir_id}.png")
        with open(path, "rb") as fh:
            data = fh.read()
        with open(dst, "wb") as fh:
            fh.write(data)
        print(f"  {ship}/{rot} -> {dir_id}: raw copy "
              f"{w}x{h} fit={fit}", flush=True)


def _pennant_fleet(ships: list[str]) -> None:
    for ship in ships:
        print(f"[snap {ship}]", flush=True)
        snap_ship(ship)


def run(ships: list[str]) -> None:
    manifest: dict = {}
    if os.path.exists(MANIFEST):
        with open(MANIFEST, encoding="utf-8") as fh:
            manifest = json.load(fh)
    for i, entry in enumerate(ships, 1):
        ship, _, label = entry.partition("=")
        rec = run_ship(ship, label or None)
        manifest[label or ship] = rec
        os.makedirs(OUT_DIR, exist_ok=True)
        with open(MANIFEST, "w", encoding="utf-8") as fh:
            json.dump(manifest, fh, indent=1, ensure_ascii=False)
        print(f"[pixellab {i}/{len(ships)}] {entry} saved "
              f"{len(rec['bytes'])} dirs", flush=True)
    print(f"[pixellab] manifest -> {MANIFEST}", flush=True)


def status() -> None:
    if not os.path.exists(MANIFEST):
        print("no manifest yet")
        return
    with open(MANIFEST, encoding="utf-8") as fh:
        m = json.load(fh)
    for ship, e in m.items():
        print(f"{ship:18s} dirs={len(e['bytes'])} seed={e['seed']} "
              f"object={e['object_id'][:12]}…")
    print(f"{len(m)} ships")


if __name__ == "__main__":
    args = sys.argv[1:]
if __name__ == "__main__":
    args = sys.argv[1:]
    # `--seed N` anywhere: the acceptance flow's seed-bumped re-roll
    seed_override = None
    if "--seed" in args:
        i = args.index("--seed")
        seed_override = int(args[i + 1])
        del args[i:i + 2]
    topdown = bool(args) and args[0] == "--topdown"
    if topdown:
        args = args[1:]
    icons = bool(args) and args[0] == "--icons"
    if icons:
        args = args[1:]
    glyphs = bool(args) and args[0] == "--glyphs"
    if glyphs:
        args = args[1:]
    cmd = args[0] if args else "status"
    if glyphs:
        if cmd == "run":
            run_glyph_fleet(args[1:] or _glyphs(), seed=seed_override)
        elif cmd == "snap":
            for glyph_id in (args[1:] or _glyphs()):
                raw = os.path.join(GLYPH_OUT_DIR, glyph_id, "icon.png")
                if not os.path.isfile(raw):
                    print(f"  {glyph_id}: no raw yet — skipped")
                    continue
                snap_glyph(glyph_id)
        else:
            status_glyphs()
    elif icons:
        if cmd == "run":
            run_icon_fleet(args[1:] or _icons(), seed=seed_override)
        elif cmd == "snap":
            for icon_id in (args[1:] or _icons()):
                if icon_id in _ICON_DESCRIPTORS or icon_id in _ICON_VARIANTS:
                    raw = os.path.join(ICON_OUT_DIR, icon_id, "icon.png")
                    if not os.path.isfile(raw):
                        print(f"  {icon_id}: no raw yet — skipped")
                        continue
                    snap_icon(icon_id)
            print("[pixellab-icons] derived-only arrow dirs and "
                  "descriptor-less ids are never generated/ingested")
        else:
            status_icons()
    elif topdown:
        if cmd == "run":
            run_topdown_fleet(args[1:] or _ships(), seed=seed_override)
        elif cmd == "snap":
            for ship in (args[1:] or _ships()):
                snap_topdown(ship)
        else:
            status_topdown()
    elif cmd == "run":
        run(sys.argv[2:] or _ships())
    elif cmd == "snap":
        _pennant_fleet(sys.argv[2:] or _ships())
    elif cmd == "fetch":
        fetch_ship(sys.argv[2],
                   sys.argv[3] if len(sys.argv) > 3 else None)
    else:
        status()
