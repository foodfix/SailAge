class_name Palette
extends RefCounted
## Placeholder-art palette and sizing grid (docs/80-UI-UX.md §4.8).
##
## Phase-1 visuals are ColorRect/Polygon2D/Label only, using these locked
## constants. No textures. Reference them as `Palette.SEA` etc.
##
## Phase-10 (§4.8): restructured append-only (IMPLEMENT-Phase10.md
## correction 9) into comment-grouped palette blocks — terrain / icon /
## hull / fx / portrait — appended after the sizing grid; every existing
## constant keeps its name, value, doc-comment and order (§4.8.4: where
## several blocks pin the same value, each block owns its own constant).

# --- Colors (locked hex, docs/80-UI-UX.md §4.8) -----------------------------

## Open water tiles.
const SEA := Color("#16446e")
## Coastal tiles.
const COAST_SEA := Color("#2f6f9e")
## Land tiles.
const LAND := Color("#7a5c2e")
## Reef tiles.
const REEF := Color("#3d3d3d")
## Polar ice tiles (`I`, impassable; docs/20-* §4.1, docs/80-* §4.8).
const ICE := Color("#c9d6df")
## Panels / HUD bars.
const PANEL_BG := Color("#1c2230")
## Borders.
const PANEL_LINE := Color("#465468")
## Primary text.
const TEXT := Color("#e8e6df")
## Focus outline, button hover.
const ACCENT := Color("#d9a441")
## Morale tier / toast: good.
const GOOD := Color("#4e9e4e")
## Morale tier / toast: warning.
const WARN := Color("#d9a441")
## Morale tier / toast: bad.
const BAD := Color("#b3341f")

## 80-* §4.8 (Phase 6): the neutral-port tier's marker/label colour —
## `nation_id: ""` ports on the world overlay and the debug chart legend
## (`10-*` §7.1 neutral tier; symbol pinned by the Phase-6 UI doc task).
const PORT_NEUTRAL := Color("#9a9a9a")

# --- Sizing grid (px, docs/80-UI-UX.md §4.8) --------------------------------

const BASE_UNIT := 8
const MARGIN := 16
const BUTTON_H := 40
const TOP_BAR_H := 40
const BOTTOM_BAR_H := 32
const ROW_H := 32
const DIALOG_W := 480

# --- Terrain block (docs/80-UI-UX.md §4.8) ----------------------------------
# (`SEA`, `COAST_SEA`, `LAND`, `REEF`, `ICE` and `PORT_NEUTRAL` above are
# this block's already-locked entries.)

## Land highlight / dither light step.
const LAND_HI := Color("#8f6d3a")
## Land shadow / dither dark step.
const LAND_LO := Color("#5e4720")
## Reef highlight / dither step.
const REEF_HI := Color("#565656")
## Ice highlight / dither light step.
const ICE_HI := Color("#e4eef4")
## Ice shadow / dither dark step.
const ICE_LO := Color("#9fb4c4")
## Shore-strip foam band (land-facing band only).
const FOAM := Color("#dff0f4")
## Port-marker silhouette ink/outline.
const PORT_INK := Color("#101010")
## Port-marker fill, portugal (docs/10-DATA-SCHEMA.md §7.4).
const PORT_PORTUGAL := Color("#1a8c4e")
## Port-marker fill, spain.
const PORT_SPAIN := Color("#b3191f")
## Port-marker fill, england.
const PORT_ENGLAND := Color("#274b8f")
## Port-marker fill, holland.
const PORT_HOLLAND := Color("#d97b1e")
## Port-marker fill, ottoman.
const PORT_OTTOMAN := Color("#6a3d9a")
## Port-marker fill, italy.
const PORT_ITALY := Color("#c9a227")

# --- Icon block (docs/80-UI-UX.md §4.8) -------------------------------------
# (`PANEL_BG`, `PANEL_LINE`, `TEXT`, `ACCENT`, `GOOD`, `BAD` and `COAST_SEA`
# above are this block's already-locked entries.)

## Icon recess shadow step.
const ICON_BG_LO := Color("#121724")
## Lit-outline step.
const ICON_LINE_HI := Color("#5e7086")
## Metal/wood mid-tone base.
const ICON_MID := Color("#232c3e")
## Specular highlight step.
const ICON_HI := Color("#f7f5ee")
## Gold highlight step.
const ACCENT_HI := Color("#f0c46a")
## Gold shadow step.
const ACCENT_LO := Color("#a87a28")
## Good highlight step.
const GOOD_HI := Color("#74c26e")
## Bad highlight step.
const BAD_HI := Color("#d4573c")
## Neutral-flag fill.
const ICON_NEUTRAL := Color("#9a9a9a")
## Flag fill, portugal.
const FLAG_PORTUGAL := Color("#1a8c4e")
## Flag fill, spain.
const FLAG_SPAIN := Color("#b3191f")
## Flag fill, england.
const FLAG_ENGLAND := Color("#274b8f")
## Flag fill, holland.
const FLAG_HOLLAND := Color("#d97b1e")
## Flag fill, ottoman.
const FLAG_OTTOMAN := Color("#6a3d9a")
## Flag fill, italy.
const FLAG_ITALY := Color("#c9a227")
## UW2 chrome skin (80-* §4.8 amended 2026-11-04, user direction — full
## option B): panel/button walnut fill for the nine-patch chrome tiles.
const PANEL_WOOD := Color("#2e2014")
## UW2 chrome skin: bevel light (top/left) / brass trim base.
const PANEL_WOOD_HI := Color("#6a4e28")
## UW2 chrome skin: bevel shadow (bottom/right) / frame dark line.
const PANEL_WOOD_LO := Color("#14100a")

# --- Hull block (docs/80-UI-UX.md §4.8) -------------------------------------
# Amended 2026-11-04 (the shared-hull pennant scheme): every owner draws the
# SAME authored map in the shared wood/sail/ink palette below; the owner is
# encoded ONLY by the masthead pennant (the authored source hex #b3191f
# remaps to the owner's PENNANT_* hex — see the appended block at the end of
# this section).  The per-owner HI/BASE/LO ramps that follow are retired
# pipeline history and stay pinned (append-only).
# Historical ramp rule (retired): HI = per-channel round(min(ch × 1.25, 255)),
# LO = per-channel round(ch × 0.72).

## Token outline (all owners, tool-applied 1px).
const HULL_INK := Color("#101010")
## Authored-neutral wood highlight.
const WOOD_HI := Color("#8f6d3a")
## Authored-neutral wood base.
const WOOD := Color("#7a5c2e")
## Authored-neutral wood shadow.
const WOOD_LO := Color("#5e4720")
## Sail highlight.
const SAIL_HI := Color("#f7f5ee")
## Sail base; also the player hull base.
const SAIL := Color("#e8e6df")
## Sail shadow.
const SAIL_LO := Color("#c2beb2")

## Player hull ramp — highlight.
const HULL_PLAYER_HI := Color("#ffffff")
## Player hull base.
const HULL_PLAYER := Color("#e8e6df")
## Player hull ramp — shadow.
const HULL_PLAYER_LO := Color("#a7a6a1")
## Portugal hull ramp — highlight.
const HULL_PORTUGAL_HI := Color("#21af62")
## Portugal hull base.
const HULL_PORTUGAL := Color("#1a8c4e")
## Portugal hull ramp — shadow.
const HULL_PORTUGAL_LO := Color("#136538")
## Spain hull ramp — highlight.
const HULL_SPAIN_HI := Color("#e01f27")
## Spain hull base.
const HULL_SPAIN := Color("#b3191f")
## Spain hull ramp — shadow.
const HULL_SPAIN_LO := Color("#811216")
## England hull ramp — highlight.
const HULL_ENGLAND_HI := Color("#315eb3")
## England hull base.
const HULL_ENGLAND := Color("#274b8f")
## England hull ramp — shadow.
const HULL_ENGLAND_LO := Color("#1c3667")
## Holland hull ramp — highlight.
const HULL_HOLLAND_HI := Color("#ff9a26")
## Holland hull base.
const HULL_HOLLAND := Color("#d97b1e")
## Holland hull ramp — shadow.
const HULL_HOLLAND_LO := Color("#9c5916")
## Ottoman hull ramp — highlight.
const HULL_OTTOMAN_HI := Color("#854cc1")
## Ottoman hull base.
const HULL_OTTOMAN := Color("#6a3d9a")
## Ottoman hull ramp — shadow.
const HULL_OTTOMAN_LO := Color("#4c2c6f")
## Italy hull ramp — highlight.
const HULL_ITALY_HI := Color("#fbcb31")
## Italy hull base.
const HULL_ITALY := Color("#c9a227")
## Italy hull ramp — shadow.
const HULL_ITALY_LO := Color("#91751c")
## Neutral hull ramp — highlight.
const HULL_NEUTRAL_HI := Color("#c1c1c1")
## Neutral hull base.
const HULL_NEUTRAL := Color("#9a9a9a")
## Neutral hull ramp — shadow.
const HULL_NEUTRAL_LO := Color("#6f6f6f")
## Pirate hull ramp — highlight.
const HULL_PIRATE_HI := Color("#e04127")
## Pirate hull base.
const HULL_PIRATE := Color("#b3341f")
## Pirate hull ramp — shadow.
const HULL_PIRATE_LO := Color("#812516")

# Amended §4.8 hull block (2026-11-04, user direction — the shared-hull
# pennant scheme): every owner draws the SAME authored map in the shared
# wood/sail/ink palette; the owner is encoded ONLY by the masthead pennant
# (the authored maps carry the authoring-only source hex #b3191f and the
# tool remaps it to the owner's PENNANT_* hex).  Wood/sail/ink are
# owner-invariant — the owner ramps above are retired from the pipeline and
# stay as pinned history (append-only: never delete or rename).

## Tier-3 trim line (1px sheer/taffrail, gilded-warship look); doubles as
## the player pennant value.
const HULL_GOLD := Color("#d9a441")
## Masthead pennant, player (= HULL_GOLD).
const PENNANT_PLAYER := Color("#d9a441")
## Masthead pennant, portugal.
const PENNANT_PORTUGAL := Color("#1a8c4e")
## Masthead pennant, spain (= the authored source hex value).
const PENNANT_SPAIN := Color("#b3191f")
## Masthead pennant, england.
const PENNANT_ENGLAND := Color("#274b8f")
## Masthead pennant, holland.
const PENNANT_HOLLAND := Color("#d97b1e")
## Masthead pennant, ottoman.
const PENNANT_OTTOMAN := Color("#6a3d9a")
## Masthead pennant, italy.
const PENNANT_ITALY := Color("#c9a227")
## Masthead pennant, neutral.
const PENNANT_NEUTRAL := Color("#9a9a9a")
## Masthead pennant, pirate.
const PENNANT_PIRATE := Color("#b3341f")

# --- FX block (docs/80-UI-UX.md §4.8) ---------------------------------------

## Cannonball body.
const FX_BALL := Color("#26262c")
## Smoke base.
const FX_SMOKE := Color("#8a929c")
## Smoke highlight frames.
const FX_SMOKE_L := Color("#c6ccd4")
## Smoke shadow frames.
const FX_SMOKE_D := Color("#555c66")
## Splash foam (same value as terrain `FOAM`; per-block ownership, §4.8.4).
const FX_FOAM := Color("#dff0f4")
## Splash water shadow.
const FX_SPLASH_D := Color("#9fc4d4")
## Impact scorch ink.
const FX_IMPACT_D := Color("#7a2d16")
## Impact fire.
const FX_FIRE := Color("#ff8c2a")
## Fire spark highlight.
const FX_SPARK := Color("#ffd23e")

# --- Portrait block (docs/80-UI-UX.md §4.8) ---------------------------------

## Portrait outline (the §4.8 table's `INK`; `PORTRAIT_`-prefixed to avoid
## the generic name — ledger adjudication).
const PORTRAIT_INK := Color("#101010")
## Skin highlight.
const SKIN_HI := Color("#f0d0b0")
## Skin base.
const SKIN := Color("#d9a878")
## Skin shadow.
const SKIN_LO := Color("#a87a52")
## Hair: black.
const HAIR_BLACK := Color("#1a1a1e")
## Hair: brown.
const HAIR_BROWN := Color("#6b4a2a")
## Hair: grey_streaked base.
const HAIR_GREY := Color("#b9bcc0")
## Grey_streaked strands.
const HAIR_STREAK := Color("#e8e6df")
## Hair: sun_bleached.
const HAIR_BLEACHED := Color("#d9b98a")
## Eyes: dark.
const EYE_DARK := Color("#2e2014")
## Eyes: grey.
const EYE_GREY := Color("#8a929c")
## Eyes: hazel.
const EYE_HAZEL := Color("#a87a28")
## Eyes: pale_blue.
const EYE_PALE_BLUE := Color("#9cc4dc")
## Cloth: trader; player trim.
const CLOTH_ACCENT := Color("#d9a441")
## Cloth: coaster.
const CLOTH_LINE := Color("#465468")
## Cloth: courier.
const CLOTH_SEA := Color("#2f6f9e")
## Cloth: hunter.
const CLOTH_GOOD := Color("#4e9e4e")
## Cloth: pirate.
const CLOTH_BAD := Color("#b3341f")
## Player cloth base.
const CLOTH_PLAYER := Color("#e8e6df")
## Cloth: patrol/privateer, owner portugal.
const CLOTH_PORTUGAL := Color("#1a8c4e")
## Cloth: patrol/privateer, owner spain.
const CLOTH_SPAIN := Color("#b3191f")
## Cloth: patrol/privateer, owner england.
const CLOTH_ENGLAND := Color("#274b8f")
## Cloth: patrol/privateer, owner holland.
const CLOTH_HOLLAND := Color("#d97b1e")
## Cloth: patrol/privateer, owner ottoman.
const CLOTH_OTTOMAN := Color("#6a3d9a")
## Cloth: patrol/privateer, owner italy.
const CLOTH_ITALY := Color("#c9a227")


## Port markers use the owning nation's color (docs/10-DATA-SCHEMA.md §7.4).
static func nation_color(hex: String) -> Color:
	return Color(hex)
