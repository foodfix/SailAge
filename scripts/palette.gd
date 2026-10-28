class_name Palette
extends RefCounted
## Placeholder-art palette and sizing grid (docs/80-UI-UX.md §4.8).
##
## Phase-1 visuals are ColorRect/Polygon2D/Label only, using these locked
## constants. No textures. Reference them as `Palette.SEA` etc.

# --- Colors (locked hex, docs/80-UI-UX.md §4.8) -----------------------------

## Open water tiles.
const SEA := Color("#16446e")
## Coastal tiles.
const COAST_SEA := Color("#2f6f9e")
## Land tiles.
const LAND := Color("#7a5c2e")
## Reef tiles.
const REEF := Color("#3d3d3d")
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

# --- Sizing grid (px, docs/80-UI-UX.md §4.8) --------------------------------

const BASE_UNIT := 8
const MARGIN := 16
const BUTTON_H := 40
const TOP_BAR_H := 40
const BOTTOM_BAR_H := 32
const ROW_H := 32
const DIALOG_W := 480


## Port markers use the owning nation's color (docs/10-DATA-SCHEMA.md §7.4).
static func nation_color(hex: String) -> Color:
	return Color(hex)
