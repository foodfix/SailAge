class_name UiTheme
extends RefCounted
## Shared control theme (docs/80-UI-UX.md §4.9, Phase 10; IMPLEMENT-Phase10.md
## §0 decisions 1–2): ONE code-built Theme — no `.tres` — applied once at
## startup to the root window (`get_window().theme` in title_screen._ready)
## and cascading to every control. Headless suites that boot scenes directly
## apply `build_theme()` themselves (the direct-boot pattern is documented in
## `tools/test_ui_theme.gd`).
##
## Pure: no node references, no scene access — the returned Theme is the only
## product. Every number is a named constant below, pinned in §4.9 (the
## "Pinned numbers" table + state matrix); every color resolves to an existing
## `palette.gd` constant (§4.9: all hexes resolve to existing constants).
## Nothing outside §4.9's table is styled here — unstyled classes keep the
## engine defaults until the W4/W5 sweep needs them.

const PaletteLib := preload("res://scripts/palette.gd")

# --- §4.9 pinned numbers (px) ------------------------------------------------

## Button/Panel border width (§4.9 Button + Panel/PanelContainer rows).
const BORDER_W := 2
## Keyboard focus ring width (§4.9 state matrix: extra 2px ACCENT ring).
const FOCUS_RING_W := 2
## Focus ring expand margin — what makes the ring sit outside the button
## (§4.9 state matrix: the "extra" ring).
const FOCUS_RING_EXPAND := 2
## Panel/PanelContainer/Tooltip corner radius (§4.9 Panel + Tooltip rows).
const RADIUS := 4
## Tooltip content margin (§4.9 Tooltip row: 8px padding).
const TOOLTIP_PAD := 8
## Scrollbar grabber thickness across the bar (§4.9 V/HScrollBar row: 8px
## grabber).
const SCROLLBAR_W := 8
## Minimum grabber length along the scroll axis (§4.9: min grabber 24px).
const GRABBER_MIN := 24
## Themed Button minimum height (§4.9 atom contract; §4.8 `Palette.BUTTON_H`).
## The pin is carried by control floors (`custom_minimum_size.y`, set by this
## screen family and by the kit atom) — see `_button_box` for why the
## stylebox padding itself stays on the grid instead of absorbing the 40px.
const BUTTON_MIN_H := 40
## LineEdit/TextEdit inset border width (§4.9: border `PANEL_LINE` — the
## 1px inset look; borders contribute no minimum size in this Godot release).
const FIELD_BORDER_W := 1
## Button content padding (§4.9 Button row: content margins ≥ 8px horizontal;
## the same BASE_UNIT 8 is the vertical padding so heights stay on the grid).
const CONTENT_PAD := 8
## Field (LineEdit/TextEdit) inner padding (§4.8 sizing grid: BASE_UNIT / 2).
const FIELD_PAD := 4
## Slider groove padding — 8px groove on the drawn axis (§4.8 BASE_UNIT).
const GROOVE_PAD := 4
## Fully transparent color — Quiet normal/hover bg + scrollbar trough
## (§4.9 state matrix: "transparent").
const TRANSPARENT := Color(0, 0, 0, 0)
## §4.9 texture-mode state mapping (amended 2026-11-04, user feedback):
## momentary click = the button sheet dimmed ×0.82; toggle-pressed (a
## held/selected card, e.g. the S2 nationality cards) = the focus sheet
## dimmed ×0.88; disabled = the button sheet dimmed ×0.45. RGB multiply
## on the per-state StyleBoxTexture `modulate_color`, alpha kept at 1.
const PRESS_MODULATE := 0.82
const TOGGLE_MODULATE := 0.88
const DISABLED_MODULATE := 0.45


## Builds the shared Theme per §4.9. Deterministic and side-effect free.
##
## `use_textures` (§4.9: "nine-patch sheets layered at W3; flat StyleBoxFlat
## remains the fallback when a texture id is absent"): when true, the
## assembled nine-patch sheets under `assets/ui/chrome/` replace the flat
## styleboxes they were generated from — per sheet, only where the file
## exists (headless suites and fresh checkouts carry no `assets/ui/`, so the
## flat fallback is what they keep getting). The bar sheet belongs to the
## kit's value_bar, not to this theme. Default true; `test_ui_theme` pins
## the flat fallback by building with `false`.
static func build_theme(use_textures: bool = true) -> Theme:
	var theme := Theme.new()
	var sheets := _load_sheets() if use_textures else {}
	_setup_button(theme, sheets, use_textures)
	_setup_scrollbars(theme)
	_setup_panels(theme, sheets)
	_setup_fields(theme, sheets, use_textures)
	_setup_sliders(theme)
	_setup_tooltips(theme)
	_setup_labels(theme, use_textures, sheets)
	return theme


# --- §4.8 Skin-coverage routing seams (amended 2026-11-05) --------------------
#
# The skin-coverage amendment routes EVERY window/panel/HUD surface through
# the skin vocabulary in texture mode; bare navy flat fills are the
# reduced-graphics fallback only. Custom-drawn screens need two read seams
# for that switch (the stylebox channels themselves stay in this file):

## Cached tri-state for [method texture_mode] (-1 unknown, 0 flat, 1 textured).
static var _texture_mode_cache: int = -1


## True when the nine-patch chrome sheets are present (texture mode ON —
## the shipped default). A missing panel sheet ⇒ the reduced-graphics flat
## fallback, and every routed surface keeps its pinned navy flat look.
static func texture_mode() -> bool:
	if _texture_mode_cache < 0:
		_texture_mode_cache = \
			1 if ResourceLoader.exists(SHEET_PATHS["panel"]) else 0
	return _texture_mode_cache == 1


## The chrome fill for plain ColorRect surfaces (§4.8 band vocabulary):
## the parchment `PARCH` in texture mode (the 2026-11-08 chrome amendment —
## the PixelLab plates are parchment), the pinned `PANEL_BG` navy in the
## reduced-graphics fallback (flat-mode pins intact).
static func surface_fill() -> Color:
	return PaletteLib.PARCH if texture_mode() else PaletteLib.PANEL_BG


# --- Nine-patch sheet variants (§4.9 layering rule) ---------------------------

## 48x48 sheets assembled by the governor from the 16x16 tiles, 16px margins
## (80-* §4.8.8); the stylebox tiles the middle regions (§4.9, the 2026-11-08
## tile-mode amendment — the prompted parchment/leather texture repeats
## instead of smearing) and the edges stay margin-fixed.
const SHEET_MARGIN := 16
const SHEET_PATHS := {
	"panel": "res://assets/ui/chrome/ninepatch_panel.png",
	"button": "res://assets/ui/chrome/ninepatch_button.png",
	"button_hover": "res://assets/ui/chrome/ninepatch_button_hover.png",
	"button_pressed": "res://assets/ui/chrome/ninepatch_button_pressed.png",
	"button_focus": "res://assets/ui/chrome/ninepatch_button_focus.png",
	"field": "res://assets/ui/chrome/ninepatch_field.png",
}


## Resolves every sheet id that exists AND loads (an absent file ⇒ the id
## stays out of the map and every consumer keeps its flat stylebox).
static func _load_sheets() -> Dictionary:
	var sheets := {}
	for key in SHEET_PATHS:
		var path: String = SHEET_PATHS[key]
		if not ResourceLoader.exists(path):
			continue
		var tex := load(path) as Texture2D
		if tex != null:
			sheets[key] = tex
	return sheets


## A nine-patch stylebox over one sheet (texture margins 16, draw region
## full — the default region_rect — and the flat box's content margins, so
## a textured button measures exactly like its flat fallback). `factor`
## is the §4.9 texture-mode state dimming: an RGB multiply on
## `modulate_color` (alpha kept at 1) that never changes measured margins.
static func _texture_box(tex: Texture2D, pad: int = 0,
		factor: float = 1.0) -> StyleBoxTexture:
	var sb := StyleBoxTexture.new()
	sb.texture = tex
	sb.texture_margin_left = SHEET_MARGIN
	sb.texture_margin_top = SHEET_MARGIN
	sb.texture_margin_right = SHEET_MARGIN
	sb.texture_margin_bottom = SHEET_MARGIN
	# §4.9 tile-mode amendment (2026-11-08): the middle regions TILE so the
	# prompted parchment/leather texture repeats instead of smearing (the
	# wang fill tile self-tiles by construction; the authored-flat sheets
	# tile identically).
	sb.axis_stretch_horizontal = StyleBoxTexture.AXIS_STRETCH_MODE_TILE
	sb.axis_stretch_vertical = StyleBoxTexture.AXIS_STRETCH_MODE_TILE
	sb.set_content_margin_all(pad)
	sb.modulate_color = Color(factor, factor, factor, 1.0)
	return sb


# --- Shared stylebox builders -------------------------------------------------

## A square-cornered StyleBoxFlat. Corner radius 0 everywhere unless the
## calling row pins otherwise (placeholder rule: colored shapes only).
static func _flat(bg: Color, border: Color, border_w: int) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = bg
	sb.set_border_width_all(border_w)
	sb.border_color = border
	sb.set_corner_radius_all(0)
	return sb


# --- Button (+ Primary/Danger/Quiet variations) --------------------------------

## One padded button box. §4.9 pins "content margins ≥ 8px horizontal"; the
## vertical margin is the same BASE_UNIT 8. Button height is enforced by
## control floors (`custom_minimum_size.y = BUTTON_MIN_H`, set by scenes and
## the kit atom) because this Godot release derives a text button's height as
## stylebox margins + font height — absorbing 40px into the margins would
## render ~60px buttons and break the §4.8 grid.
static func _button_box(bg: Color, border: Color, border_w: int = BORDER_W) -> StyleBoxFlat:
	var sb := _flat(bg, border, border_w)
	sb.set_content_margin_all(CONTENT_PAD)
	return sb


## The keyboard focus ring (§4.9 state matrix): a 2px `accent` ring drawn
## outside the button — draw_center off, expand margin = the "extra" ring.
static func _focus_ring(accent: Color) -> StyleBoxFlat:
	var sb := _flat(TRANSPARENT, accent, FOCUS_RING_W)
	sb.draw_center = false
	sb.set_expand_margin_all(FOCUS_RING_EXPAND)
	return sb


static func _setup_button(theme: Theme, sheets: Dictionary = {},
		use_textures: bool = true) -> void:
	# §4.9 Button row + state matrix, with the amended 2026-11-08
	# PixelLab-chrome mapping: normal = button sheet; hover = button_hover
	# sheet (the baked glow); momentary pressed = button_pressed sheet (the
	# baked 180°-rim sunken plate — modulate-free); hover∩pressed =
	# button_pressed; disabled = button sheet ×DISABLED_MODULATE (+ the
	# PANEL_LINE disabled text); keyboard focus = button_focus sheet. A
	# missing hover/pressed sheet falls back to the 2026-11-04 ladder
	# (hover = focus sheet; pressed = button ×PRESS_MODULATE), which remains
	# the degraded mode. Every state box keeps the CONTENT_PAD margins, so a
	# state flip can never change a button's measured size. The variations
	# keep their flat boxes — the sheet family has no Danger/Quiet variants,
	# and their identity IS the colored border.
	var normal_box: StyleBox = null
	var hover_box: StyleBox = null
	var pressed_box: StyleBox = null
	var disabled_box: StyleBox = null
	var hover_pressed_box: StyleBox = null
	if sheets.has("button"):
		normal_box = _texture_box(sheets["button"], CONTENT_PAD)
		disabled_box = _texture_box(sheets["button"], CONTENT_PAD,
			DISABLED_MODULATE)
		if sheets.has("button_pressed"):
			pressed_box = _texture_box(sheets["button_pressed"],
				CONTENT_PAD)
		else:
			# 2026-11-04 degraded ladder: the dimmed plain sheet.
			pressed_box = _texture_box(sheets["button"], CONTENT_PAD,
				PRESS_MODULATE)
		# Pressed under the mouse draws the pressed cell too (the matrix has
		# no separate hover∩pressed cell).
		hover_pressed_box = pressed_box
		if sheets.has("button_hover"):
			hover_box = _texture_box(sheets["button_hover"], CONTENT_PAD)
		elif sheets.has("button_focus"):
			hover_box = _texture_box(sheets["button_focus"], CONTENT_PAD)
		else:
			# Both absent ⇒ hover keeps the plain sheet (the W3
			# fallback rule: absent id ⇒ flat/nearest fallback, no crash).
			hover_box = normal_box
	else:
		normal_box = _button_box(PaletteLib.PANEL_BG, PaletteLib.PANEL_LINE)
		hover_box = _button_box(PaletteLib.PANEL_BG, PaletteLib.ACCENT)
		pressed_box = _button_box(PaletteLib.PANEL_LINE, PaletteLib.PANEL_LINE)
	theme.set_stylebox("normal", "Button", normal_box)
	theme.set_stylebox("hover", "Button", hover_box)
	theme.set_stylebox("pressed", "Button", pressed_box)
	if disabled_box != null:
		# §4.9 texture-mode mapping: disabled = button sheet ×0.45. Without
		# sheets the engine default disabled box stays (the flat matrix pins
		# only the disabled TEXT color).
		theme.set_stylebox("disabled", "Button", disabled_box)
	if hover_pressed_box != null:
		theme.set_stylebox("hover_pressed", "Button", hover_pressed_box)
	# Keyboard focus: the ACCENT ring — flat draw_center-off ring, or the
	# button_focus sheet's ACCENT border ring (its fill ships transparent).
	if sheets.has("button_focus"):
		theme.set_stylebox("focus", "Button",
			_texture_box(sheets["button_focus"]))
	else:
		theme.set_stylebox("focus", "Button", _focus_ring(PaletteLib.ACCENT))
	# Text rides the §4.9 ink seam (2026-11-08 evening): the click plate is
	# light parchment — ink text in texture mode (the card children's Label
	# ink becomes correct by design), cream in the flat fallback; disabled
	# text dims to ink at 0.55 alpha in texture mode, PANEL_LINE flat.
	var button_ink: Color = (PaletteLib.INK_WARM
			if _ink_mode(use_textures, sheets) else PaletteLib.TEXT)
	var button_ink_dim: Color = (Color(PaletteLib.INK_WARM, 0.55)
			if _ink_mode(use_textures, sheets) else PaletteLib.PANEL_LINE)
	theme.set_color("font_color", "Button", button_ink)
	theme.set_color("font_hover_color", "Button", button_ink)
	theme.set_color("font_pressed_color", "Button", button_ink)
	theme.set_color("font_hover_pressed_color", "Button", button_ink)
	theme.set_color("font_focus_color", "Button", button_ink)
	theme.set_color("font_disabled_color", "Button", button_ink_dim)

	# Theme variations (§4.9 state matrix; Godot 4 `Theme.set_type_variation`).
	# `Toggle` carries the amended texture-mode mapping's toggle-pressed cell:
	# a held/selected card (the S2 nationality cards, the S20 background
	# cards) shows the focus sheet ×TOGGLE_MODULATE — a persistent ACCENT
	# ring, distinct from plain hover (the same sheet at ×1.0) and from the
	# momentary ×0.82 press. normal/hover/focus/disabled resolve through the
	# Button variation base at runtime; without the focus sheet the variation
	# registers nothing and resolves everything through Button.
	if sheets.has("button_focus"):
		theme.set_type_variation("Toggle", "Button")
		theme.set_stylebox("pressed", "Toggle",
			_texture_box(sheets["button_focus"], CONTENT_PAD, TOGGLE_MODULATE))
		theme.set_stylebox("hover_pressed", "Toggle",
			_texture_box(sheets["button_focus"], CONTENT_PAD, TOGGLE_MODULATE))
	# `Primary` re-pins the same ACCENT slots as the default Button — it is
	# registered anyway so kit kind selection (default/primary/danger) is
	# uniform. Pressed/disabled resolve through the variation base.
	theme.set_type_variation("Primary", "Button")
	theme.set_stylebox("hover", "Primary",
		_button_box(PaletteLib.PANEL_BG, PaletteLib.ACCENT))
	theme.set_stylebox("focus", "Primary", _focus_ring(PaletteLib.ACCENT))
	# `Danger` swaps every border/accent slot to BAD — normal/hover/pressed
	# borders and the focus ring alike (pressed keeps the PANEL_LINE bg).
	theme.set_type_variation("Danger", "Button")
	theme.set_stylebox("normal", "Danger",
		_button_box(PaletteLib.PANEL_BG, PaletteLib.BAD))
	theme.set_stylebox("hover", "Danger",
		_button_box(PaletteLib.PANEL_BG, PaletteLib.BAD))
	theme.set_stylebox("pressed", "Danger",
		_button_box(PaletteLib.PANEL_LINE, PaletteLib.BAD))
	theme.set_stylebox("focus", "Danger", _focus_ring(PaletteLib.BAD))
	# `Quiet` is borderless chrome until hover: transparent bg, no border in
	# normal; hover brings the ACCENT border on a transparent bg. Pressed /
	# focus / disabled resolve through the Button variation base at runtime
	# (the matrix's "Button hover/pressed cells").
	theme.set_type_variation("Quiet", "Button")
	theme.set_stylebox("normal", "Quiet", _button_box(TRANSPARENT, TRANSPARENT, 0))
	theme.set_stylebox("hover", "Quiet", _button_box(TRANSPARENT, PaletteLib.ACCENT))


# --- VScrollBar / HScrollBar ---------------------------------------------------

## One grabber box. The 8px thickness and the 24px minimum grabber length are
## carried by the stylebox content margins: this Godot release derives the
## bar's across-axis minimum and the shortest drawn grabber from them
## (verified: themed VScrollBar min (8, 24), HScrollBar min (24, 8)).
static func _grabber_box(bg: Color, vertical: bool) -> StyleBoxFlat:
	var sb := _flat(bg, TRANSPARENT, 0)
	var across := SCROLLBAR_W / 2  # margins per side → 8px bar
	var along := GRABBER_MIN / 2   # margins per side → 24px min grabber
	sb.content_margin_left = along if not vertical else across
	sb.content_margin_right = along if not vertical else across
	sb.content_margin_top = across if not vertical else along
	sb.content_margin_bottom = across if not vertical else along
	return sb


static func _setup_scrollbars(theme: Theme) -> void:
	# §4.9 V/HScrollBar row: transparent trough; 8px `PANEL_LINE` grabber,
	# hover/pressed `ACCENT`, min grabber 24px. The trough carries the bar's
	# across-axis minimum and the grabber the along-axis one (this release
	# derives ScrollBar minimums from those margins; verified: themed
	# VScrollBar min (8, 24), HScrollBar min (24, 8)).
	for type_name in ["VScrollBar", "HScrollBar"]:
		var vertical: bool = type_name == "VScrollBar"
		var trough := _flat(TRANSPARENT, TRANSPARENT, 0)
		var across := SCROLLBAR_W / 2  # margins per side → 8px bar
		trough.content_margin_left = across if vertical else 0
		trough.content_margin_right = across if vertical else 0
		trough.content_margin_top = 0 if vertical else across
		trough.content_margin_bottom = 0 if vertical else across
		theme.set_stylebox("scroll", type_name, trough)
		theme.set_stylebox("grabber", type_name,
			_grabber_box(PaletteLib.PANEL_LINE, vertical))
		theme.set_stylebox("grabber_highlight", type_name,
			_grabber_box(PaletteLib.ACCENT, vertical))
		theme.set_stylebox("grabber_pressed", type_name,
			_grabber_box(PaletteLib.ACCENT, vertical))


# --- Panel / PanelContainer ----------------------------------------------------

static func _panel_box() -> StyleBoxFlat:
	var sb := _flat(PaletteLib.PANEL_BG, PaletteLib.PANEL_LINE, BORDER_W)
	sb.set_corner_radius_all(RADIUS)
	return sb


static func _setup_panels(theme: Theme, sheets: Dictionary = {}) -> void:
	# §4.9 Panel/PanelContainer row: PANEL_BG + 2px PANEL_LINE, radius 4
	# (nine-patch sheets layer over this flat fallback at W3).
	var panel_box: StyleBox = null
	if sheets.has("panel"):
		panel_box = _texture_box(sheets["panel"])
	else:
		panel_box = _panel_box()
	theme.set_stylebox("panel", "Panel", panel_box)
	theme.set_stylebox("panel", "PanelContainer", panel_box)


## The §4.9 ink seam (2026-11-08 chrome amendment): true when the texture
## theme is actually shipping sheets — panel-surface text rides `INK_WARM`
## (parchment contrast) instead of the flat-mode cream pins.
static func _ink_mode(use_textures: bool, sheets: Dictionary) -> bool:
	return use_textures and sheets.has("panel")


# --- LineEdit / TextEdit -------------------------------------------------------

static func _setup_fields(theme: Theme, sheets: Dictionary = {},
		use_textures: bool = true) -> void:
	# §4.9 LineEdit/TextEdit row: bg PANEL_BG, border PANEL_LINE (the 1px
	# inset look), focus border ACCENT; text + caret TEXT. The W3 texture
	# variant swaps the normal box to ninepatch_field (focus/read_only keep
	# their flat boxes — the sheet family pins no ACCENT variant). The state
	# matrix's disabled cell (text PANEL_LINE) maps to this release's
	# uneditable-text color, and the read_only box mirrors normal so the
	# field stays on palette.
	for type_name in ["LineEdit", "TextEdit"]:
		var normal: StyleBox
		if sheets.has("field"):
			normal = _texture_box(sheets["field"], FIELD_PAD)
		else:
			normal = _flat(PaletteLib.PANEL_BG, PaletteLib.PANEL_LINE,
				FIELD_BORDER_W)
			normal.set_content_margin_all(FIELD_PAD)
		theme.set_stylebox("normal", type_name, normal)
		var focus := _flat(PaletteLib.PANEL_BG, PaletteLib.ACCENT, FIELD_BORDER_W)
		focus.set_content_margin_all(FIELD_PAD)
		theme.set_stylebox("focus", type_name, focus)
		var read_only := _flat(PaletteLib.PANEL_BG, PaletteLib.PANEL_LINE, FIELD_BORDER_W)
		read_only.set_content_margin_all(FIELD_PAD)
		theme.set_stylebox("read_only", type_name, read_only)
		# §4.9 ink seam (2026-11-08): the field sheet is inset parchment in
		# texture mode — ink text; flat mode keeps cream on navy.
		var field_ink: Color = (PaletteLib.INK_WARM
				if _ink_mode(use_textures, sheets) else PaletteLib.TEXT)
		theme.set_color("font_color", type_name, field_ink)
		theme.set_color("caret_color", type_name, field_ink)
	# The uneditable-text item name differs between the two classes (verified
	# against this Godot release).
	theme.set_color("font_uneditable_color", "LineEdit", PaletteLib.PANEL_LINE)
	theme.set_color("font_readonly_color", "TextEdit", PaletteLib.PANEL_LINE)


# --- HSlider / VSlider ---------------------------------------------------------

static func _setup_sliders(theme: Theme) -> void:
	# §4.9 Slider row (S19): groove PANEL_LINE, grabber_area (and highlight)
	# ACCENT. The grabber icon itself stays the engine's default placeholder
	# icon — no textures in W2.
	for type_name in ["HSlider", "VSlider"]:
		var groove := _flat(PaletteLib.PANEL_LINE, TRANSPARENT, 0)
		groove.set_content_margin_all(GROOVE_PAD)
		theme.set_stylebox("slider", type_name, groove)
		var area := _flat(PaletteLib.ACCENT, TRANSPARENT, 0)
		area.set_content_margin_all(GROOVE_PAD)
		theme.set_stylebox("grabber_area", type_name, area)
		var area_highlight := _flat(PaletteLib.ACCENT, TRANSPARENT, 0)
		area_highlight.set_content_margin_all(GROOVE_PAD)
		theme.set_stylebox("grabber_area_highlight", type_name, area_highlight)


# --- Tooltips ------------------------------------------------------------------

static func _setup_tooltips(theme: Theme) -> void:
	# §4.9 Tooltip row: bg PANEL_BG, radius 4, 8px padding; text TEXT.
	var panel := _flat(PaletteLib.PANEL_BG, TRANSPARENT, 0)
	panel.set_corner_radius_all(RADIUS)
	panel.set_content_margin_all(TOOLTIP_PAD)
	theme.set_stylebox("panel", "TooltipPanel", panel)
	theme.set_color("font_color", "TooltipLabel", PaletteLib.TEXT)


# --- Label (+ Dim variation) ---------------------------------------------------

static func _setup_labels(theme: Theme, use_textures: bool = true,
		sheets: Dictionary = {}) -> void:
	# §4.9 Label row: TEXT, plus the `Dim` variation (PANEL_LINE) for
	# secondary row text. §4.9 ink seam (2026-11-08 chrome amendment): in
	# texture mode the panels are parchment — Label/Dim ride the warm ink
	# (`Dim` = ink at 0.75 alpha) and `Accent`/`Warn` swap to `ACCENT_LO`
	# for parchment contrast; `Good`/`Bad` keep their semantic hexes (both
	# read on parchment); flat mode keeps the cream pins.
	var ink: bool = _ink_mode(use_textures, sheets)
	var label_ink: Color = PaletteLib.INK_WARM if ink else PaletteLib.TEXT
	var dim_ink: Color = Color(PaletteLib.INK_WARM, 0.75) if ink \
			else PaletteLib.PANEL_LINE
	var accent_ink: Color = PaletteLib.ACCENT_LO if ink \
			else PaletteLib.ACCENT
	theme.set_color("font_color", "Label", label_ink)
	theme.set_type_variation("Dim", "Label")
	theme.set_color("font_color", "Dim", dim_ink)
	# Semantic Label variations (Phase-10 W4 master adjudication, ledgered):
	# the doc-pinned tier/accent TEXT colors (80-* §4.8.1 status lines, the
	# §4.5/§4.6.1 tier-colored readouts, market/§4.7 accent marks) ride
	# theme_type_variation assignments — a plain property, gate-compliant
	# (no add_theme_* override). WARN == ACCENT by hex (palette).
	theme.set_type_variation("Accent", "Label")
	theme.set_color("font_color", "Accent", accent_ink)
	theme.set_type_variation("Warn", "Label")
	theme.set_color("font_color", "Warn",
			PaletteLib.ACCENT_LO if ink else PaletteLib.WARN)
	theme.set_type_variation("Good", "Label")
	theme.set_color("font_color", "Good", PaletteLib.GOOD)
	theme.set_type_variation("Bad", "Label")
	theme.set_color("font_color", "Bad", PaletteLib.BAD)
	# §4.8.1: the S4 facility card's pinned 12px status line (theme-owned
	# size — the per-screen font-size override channel is retired).
	theme.set_type_variation("CardStatus", "Label")
	theme.set_font_size("font_size", "CardStatus", 12)
	theme.set_type_variation("CardStatusGood", "Label")
	theme.set_font_size("font_size", "CardStatusGood", 12)
	theme.set_color("font_color", "CardStatusGood", PaletteLib.GOOD)
	theme.set_type_variation("CardStatusDim", "Label")
	theme.set_font_size("font_size", "CardStatusDim", 12)
	theme.set_color("font_color", "CardStatusDim", dim_ink)
