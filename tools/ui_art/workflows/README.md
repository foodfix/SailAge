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

  | seed  | save prefix (under `output/`) | dir | view |
  |---|---|---|---|
  | 91001 | `sailage/angles/n`  | n  | astern, stern-castle head-on |
  | 91002 | `sailage/angles/s`  | s  | bow, bowsprit at the viewer |
  | 91003 | `sailage/angles/nw` | nw | bow TOP-LEFT, sails to BOTTOM-RIGHT |
  | 91004 | `sailage/angles/sw` | sw | bow BOTTOM-LEFT, sails to TOP-RIGHT |

  The diagonal/orthogonal wording is verbatim from the game's POSE table
  (`tools/model_pass.py`), so outputs match what the snap/ingest gates
  (band, pennant-in-masthead, palette block) expect.

- **Every prompt pins**: same hull/rig/mast count/sail layout/colors,
  mast+sail height unchanged, red pennant at the mainmast top (the G13
  masthead gate), flat `#00ff00` chroma background, no water/scenery/
  text/frame.

- **First-run checks**: (1) diagonal mirror — if a 45° branch renders the
  bow in the wrong corner, swap the two 45° prompt texts (the dir id is
  decided by the filename at ingest, not the camera wording); (2) astern/
  bow mix-up on the 90° pair — likewise swap.

Downstream (not yet doc-amended): each accepted angle goes through the
same snap path as the studio flow (`80-*` §4.8 ingestion contract) to
become `hull_<ship>_<owner>_<dir>.png`.
