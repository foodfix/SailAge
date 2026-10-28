extends Control
## Title screen (S1) — docs/80-UI-UX.md §4.1.
##
## T1 scaffold: brand title + phase tag only. T16/T17 add the New/Load rows and
## the locale toggle button. Colors and grid spacing come from Palette
## (docs/80-UI-UX.md §4.8) so the scene cannot drift from the locked values.
##
## Palette is preloaded rather than referenced through its global class name so
## the scene also runs before the editor has written Godot's global-class cache.

const PaletteLib := preload("res://scripts/palette.gd")

@onready var _background: ColorRect = $Background
@onready var _stack: VBoxContainer = $Center/Stack
@onready var _title: Label = $Center/Stack/GameTitle
@onready var _phase_tag: Label = $Center/Stack/PhaseTag


func _ready() -> void:
	_background.color = PaletteLib.PANEL_BG
	_stack.add_theme_constant_override("separation", PaletteLib.MARGIN)
	_title.add_theme_color_override("font_color", PaletteLib.TEXT)
	_phase_tag.add_theme_color_override("font_color", PaletteLib.PANEL_LINE)
