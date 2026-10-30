class_name ChartView
extends RefCounted
## Shared rendering model for the two map views of the world (docs/80-UI-UX.md
## §4.5/§4.6, docs/20-WORLD-AND-SAILING.md §4.12):
##
##   * the HUD **minimap crop** — 256×192 px, a wrap-aware 128×96-tile window
##     around the fleet at 2 px/tile (`scenes/ui_shared/hud.gd`);
##   * the full-screen **Chart** (S17) — the whole 2160×1080 grid downscaled to
##     fit (`scenes/world/chart_screen.gd`).
##
## Both must show **identical** explored content, so neither scene decides what
## is explored, which port is known or which colour a tile has: those rules live
## here, once, as pure static functions over the session state.
##
## **Never mutates anything.** Every function only reads `GameState`,
## `DataLoader` and the `MapLoader` handed to it (docs/80-* §4.6: the Chart is
## "a pure view of the session").
##
## **Explored state container.** `GameState.explored_tiles` is the Phase-1
## dictionary (`20-*` §4.12 / `90-*` §5.4 describe the intended
## `PackedByteArray` of 291,600 bytes). Phase 4 keeps the dictionary: the phase
## acceptance is identical *content* between the two views, and migrating the
## container would touch `autoload/game_state.gd`, `autoload/save_system.gd`,
## `scenes/world/world_map.gd#_reveal` and five suites owned by other tasks.
## Every read goes through [method is_explored], so that migration later is a
## one-file change here.
##
## `Palette` is preloaded rather than referenced through its global class name so
## this script also runs before Godot has written its class cache.

const PaletteLib := preload("res://scripts/palette.gd")
const DiscoveryLib := preload("res://scripts/world/discovery.gd")

## The fog colour of an unexplored tile: `PANEL_BG` on the Chart (`80-*` §4.6)
## and the minimap's background (`20-*` §4.12).
const UNKNOWN_COLOR := PaletteLib.PANEL_BG


# --- Explored state (docs/20-* §4.12) --------------------------------------

## `true` when the session has revealed `cell`. x wraps (`20-*` §4.1); y must be
## on the grid. This is the single read path for both views.
static func is_explored(cell: Vector2i, map = null) -> bool:
	if cell.y < 0:
		return false
	if map != null and int(map.height) > 0 and cell.y >= int(map.height):
		return false
	if map != null and int(map.width) > 0:
		cell = Vector2i(posmod(cell.x, int(map.width)), cell.y)
	return GameState.explored_tiles.has(cell)


## How many tiles the session has explored (cheap: dictionary size).
static func explored_count() -> int:
	return GameState.explored_tiles.size()


# --- Terrain colours (docs/80-* §4.8) --------------------------------------

## Palette colour of a legend `kind`. `polar_ice` is the Phase-4 `I` tile
## (`80-*` §4.8 `ICE`) — the one kind the Phase-1–3 minimap never had to draw.
static func terrain_color(kind: String) -> Color:
	match kind:
		"sea":
			return PaletteLib.SEA
		"coastal_sea":
			return PaletteLib.COAST_SEA
		"land":
			return PaletteLib.LAND
		"reef":
			return PaletteLib.REEF
		"polar_ice":
			return PaletteLib.ICE
		_:
			return PaletteLib.PANEL_LINE


## `palette_index → Color` for the loaded map, resolved through the legend's own
## `kind` strings (data-driven: a swapped `map_legend.json` needs no code edit).
## Built once per image build, so the per-tile loop is a list lookup.
static func palette_colors(map) -> Array:
	var out: Array = []
	if map == null:
		return out
	var by_char: Dictionary = map.palette_chars
	var max_index := -1
	for ch in by_char:
		max_index = maxi(max_index, int(by_char[ch]))
	for index in max_index + 1:
		out.append(PaletteLib.PANEL_LINE)
	for ch in by_char:
		var index := int(by_char[ch])
		var def = (map.legend_tiles as Dictionary).get(ch, null)
		var kind := ""
		if def is Dictionary and (def as Dictionary).get("kind", "") is String:
			kind = str((def as Dictionary)["kind"])
		out[index] = terrain_color(kind)
	return out


## Colour of the tile at `(x, y)` from a table built by [method palette_colors],
## `UNKNOWN_COLOR` for out-of-grid cells. x wraps.
static func index_color(colors: Array, map, x: int, y: int) -> Color:
	if map == null or y < 0 or y >= int(map.height) or int(map.width) <= 0:
		return UNKNOWN_COLOR
	var index := int(map.indices[y * int(map.width) + posmod(x, int(map.width))])
	if index < 0 or index >= colors.size():
		return UNKNOWN_COLOR
	return colors[index]


## What the minimap and the Chart both draw for `cell`: the explored terrain
## colour, or the fog colour when the tile is unknown (`80-*` §4.6 layers).
## `colors` is a table from [method palette_colors] (pass it in: a caller
## sampling many cells builds it once).
static func explored_color(colors: Array, map, cell: Vector2i) -> Color:
	if not is_explored(cell, map):
		return UNKNOWN_COLOR
	return index_color(colors, map, cell.x, cell.y)


# --- Layers (docs/80-* §4.6, docs/20-* §4.12) ------------------------------

## The known-port dots both views draw, `[{port_id, cell, color, name}]` sorted
## by port id: **known ports only**, at their derived harbor tile, in their
## nation's colour (`20-*` §4.12, `80-*` §4.6). `name` is the localised port
## name (`""` before a locale/data exists); only the Chart's zoomed label uses
## it, but both views share the list so they can never disagree about *which*
## ports are known.
static func port_dots(map, nations: Dictionary = {}) -> Array:
	var out: Array = []
	if map == null:
		return out
	var nation_table: Dictionary = nations if not nations.is_empty() else DataLoader.nations
	var ids: Array = GameState.known_ports.duplicate()
	ids.sort()
	for raw_id in ids:
		var port_id := str(raw_id)
		var cell: Vector2i = map.port_cell(port_id)
		if cell.x < 0:
			continue
		var port: Dictionary = DataLoader.get_port(port_id)
		out.append({
			"port_id": port_id,
			"cell": cell,
			"color": _nation_color(str(port.get("nation_id", "")), nation_table),
			"name": _port_name(port),
		})
	return out


## Discovery markers both views draw: `[{id, cell}]`, sorted by id, for every
## **found** discovery whose tile is explored (`20-*` §4.12: "Found discoveries
## are drawn … once explored"). A found discovery is the session's only
## per-tile discovery knowledge; a tavern hint is text, not a marker, and the
## Chart never reveals a position the player has not seen.
static func lead_cells(map) -> Array:
	var out: Array = []
	if map == null:
		return out
	var ids: Array = GameState.discoveries_found.duplicate()
	ids.sort()
	for raw_id in ids:
		var discovery_id := str(raw_id)
		var cell: Vector2i = _discovery_cell(discovery_id)
		if cell.x < 0 or not is_explored(cell, map):
			continue
		out.append({"id": discovery_id, "cell": cell})
	return out


static func _discovery_cell(discovery_id: String) -> Vector2i:
	var entry: Dictionary = DataLoader.get_discovery(discovery_id)
	if entry.is_empty():
		return Vector2i(-1, -1)
	return DiscoveryLib.position_of_entry(entry)


static func _nation_color(nation_id: String, nations: Dictionary) -> Color:
	var nation = nations.get(nation_id, null)
	if nation is Dictionary:
		var hex = (nation as Dictionary).get("color", "")
		if hex is String and Color.html_is_valid(hex):
			return PaletteLib.nation_color(hex)
	return PaletteLib.ACCENT


static func _port_name(port: Dictionary) -> String:
	var name = port.get("name", null)
	if not (name is Dictionary) or (name as Dictionary).is_empty():
		return ""
	return I18n.t(name)


# --- Geometry --------------------------------------------------------------

## A world x taken mod the grid width (`20-*` §4.1).
static func wrap_x(x: int, width: int) -> int:
	return posmod(x, maxi(width, 1))
