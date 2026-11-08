# ComfyUI workflow templates (committed tool assets)

Manual-stage workflows run in the ComfyUI UI (http://127.0.0.1:8000).
Outputs are raw model output — never committed (90-* §9.2); they feed the
accept→snap→ingest funnel like any other model pass.

## ship_multi_angle.json — stage 2 of the multi-angle ship token pipeline

API-format workflow: Qwen-Image-21-turbo + `TextEncodeQwenImageEditPlus`
+ the multiple-angles LoRA
(`angles_v2_full_qwen21_multiple_angles_v2_..._000001500.safetensors`,
strength 1.0; drop to ~0.8 if hull identity drifts).

- **Input** (node 25): the hi-res side view from `tools/sideview_pass.py`
  (`model_raw/sideviews/<ship>_side.png`, bow LEFT = the `w` pose, flat
  `#00ff00` green bg). Copy it into ComfyUI's input dir and edit the
  LoadImage filename per ship.
- **Branches** → the 4 base dirs the model must generate (`w` IS the
  input; `e/ne/se` are exact h-flips derived at ingestion, doc f6c00bb):

  | seed  | save prefix (under `output/`) | dir | view | orbit |
  |---|---|---|---|---|
  | 91001 | `sailage/angles/n`  | n  | astern, stern-castle head-on | 90° clockwise |
  | 91002 | `sailage/angles/s`  | s  | bow, bowsprit at the viewer | 90° anticlockwise |
  | 91003 | `sailage/angles/nw` | nw | bow TOP-LEFT, sails to BOTTOM-RIGHT | 45° clockwise |
  | 91004 | `sailage/angles/sw` | sw | bow BOTTOM-LEFT, sails to TOP-RIGHT | 45° anticlockwise |

  The diagonal/orthogonal wording is verbatim from the game's POSE table
  (the retired `tools/model_pass.py` — kept in git history), so outputs
  matched what the snap/ingest gates (band, pennant-in-masthead,
  palette block) expected. The whole angle workflow is RETIRED with the
  2026-11-07 top-down amendment (one north token per ship; the runtime
  rotates).

- **Orbit convention (empirical, brigantine trials 2026-11-05/06):** the
  input faces WEST (bow LEFT). From that view, the **clockwise** orbit
  (seen from above, S→W) swings the bow UP — it produces the astern-side
  family (n, nw); the **anticlockwise** orbit (S→E) swings the bow DOWN —
  the bow-side family (s, sw). Equivalently: the LoRA's "rotate the
  camera to the right" ≡ clockwise, "to the left" ≡ anticlockwise for a
  west-facing subject (both earlier phrasings rendered exactly this way).
  The orbit word alone decides the family; the POSE corner text only
  refines it — do not rely on the corner text against the orbit word.

- **Every prompt pins**: same hull/rig/mast count/sail layout/colors,
  mast+sail height unchanged, red pennant at the mainmast top (the G13
  masthead gate), flat `#00ff00` chroma background, no water/scenery/
  text/frame. **Plus a style clause on all four branches** ("crisp
  limited-palette pixel art matching the input image's style, strong
  1-pixel dark outline, big chunky pixels, dense wooden hull with
  planking lines, lit cabin windows, gunports") — added after the
  brigantine trial showed the 90° branches drifting painterly; it raised
  snapped-pixel density on every dir (n 13.4→15.3%, s 10.4→13.3%,
  nw 16.1→19.5%, sw 17.4→21.5%). A follow-up "flat color fills, no
  dithering" clause was trialed and kept: neutral on density, slightly
  cleaner sails; the residual n/s speckle is genuine rigging detail
  compressing into ~15 pixel columns (the intrinsic floor for dead-on
  views at 64px), not dithering — accepted 2026-11-06, user review.

- **Known render traits (raw output, pre-snap):** backgrounds are green
  but never exactly `#00ff00` (VAE decode; `n` may carry a soft radial
  gradient) — the tokenize path's rembg + key_green handles it; `n`/`s`
  come out slightly painterly versus the flat cel side view — mostly
  washes out at the 32-grid snap. Do NOT add anti-flat/tilt clauses: the
  tilt wording distorted the hull (brigantine trial).

Downstream (not yet doc-amended): each accepted angle goes through the
same snap path as the studio flow (`80-*` §4.8 ingestion contract) to
become `hull_<ship>_<owner>_<dir>.png`.
