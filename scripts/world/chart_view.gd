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
## Phase-6 seasonal layers: the rasters + ice polygons decode in the one
## owner module (IMPLEMENT-Phase6 correction 15); the debug gate is read
## through the settings-panel script resource in `debug_row_enabled` (C's
## pinned `SettingsPanel.debug_overlays` symbol contract).
const OceanLayersLib := preload("res://scripts/world/ocean_layers.gd")
const NpcFleetsLib := preload("res://scripts/world/npc_fleets.gd")
const SailingSimLib := preload("res://scripts/world/sailing_sim.gd")

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

## The known-port dots both views draw, `[{port_id, cell, berth_cell, color,
## name}]` sorted by port id: **known ports only**, at their derived **shore**
## tile — the land tile the player reads as the port (`20-*` §4.11.1) — in their
## nation's colour (`20-*` §4.12, `80-*` §4.6). `berth_cell` is the sea tile the
## fleet stands on (kept for callers that need the water access point, e.g. a
## proximity test). `name` is the localised port
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
		var berth: Vector2i = map.port_cell(port_id)
		if berth.x < 0:
			continue
		var cell: Vector2i = map.shore_cell(port_id)
		if cell.x < 0:
			# A berth with no shore tile is a data error (validator group 6
			# item 2b); the chart still marks the water access point.
			cell = berth
		var port: Dictionary = DataLoader.get_port(port_id)
		out.append({
			"port_id": port_id,
			"cell": cell,
			"berth_cell": berth,
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


# --- Phase-6 seasonal layers (docs/80-* §4.6; IMPLEMENT-Phase6.md §2.9/§2.12) ---

## The S19 调试图层 row (C's pinned symbol: `SettingsPanel.debug_overlays`,
## static, session-only, default false). **Guard-read** (IMPLEMENT-Phase6
## correction 12): the row is task V's — until it merges the static is absent,
## and `Script.get` answers null, which reads as off, exactly the documented
## default. `debug_row_override` is the documented test seam (-1 = follow the
## row; 0/1 force it) so W5 suites are independent of V's merge order.
static var debug_row_override := -1
## The settings-panel *script resource* as a runtime value (a `preload`
## constant resolves to a class, whose members the analyzer checks; the
## guard-read must tolerate the symbol being absent, so it reads through the
## object instead).
static var _settings_script: Script = null


static func debug_row_enabled() -> bool:
	if debug_row_override == 0:
		return false
	if debug_row_override == 1:
		return true
	if _settings_script == null:
		_settings_script = load("res://scenes/ui_shared/settings_panel.gd")
	var value = _settings_script.get("debug_overlays") \
		if _settings_script != null else null
	return true if (value is bool) else false


## The neutral-port grey (`80-*` §4.8 pins `PORT_NEUTRAL` in `palette.gd`).
## Guard-read, same convention as the debug row: pre-merge the constant is
## absent and the §4.8 hex is used verbatim.
const PORT_NEUTRAL_HEX := "#9a9a9a"


static func port_neutral_color() -> Color:
	var palette_script: Script = load("res://scripts/palette.gd")
	var value = palette_script.get("PORT_NEUTRAL") \
		if palette_script != null else null
	return value if (value is Color) else Color(PORT_NEUTRAL_HEX)


## Season-arrow sampling (`80-*` §4.6 "arrows per region"): the wind layer
## draws **one arrow per wind region**. The probe starts at the region
## polygon's tile-space centroid and falls back to a coarse lattice over the
## polygon's tile-space bounding box — `max(bbox)/REGION_PROBE_STEPS` stride,
## first interior water tile whose raster id is the region's. (The rasters
## paint water only, so a centroid on land walks out to the region.)
const REGION_PROBE_STEPS := 24


## The wind layer for `month` (1..12): one arrow per region,
## `[{region_id, id, cell, token, variable}]` in file order. `token` is the
## §4.14 wind-FROM token; `variable` marks a `VAR` region (the distinctive
## placeholder glyph). Read-only.
static func wind_arrows(month: int, ocean = null) -> Array:
	var layers = ocean if ocean != null else OceanLayersLib.instance()
	if not layers.decode_ok or month < 1 or month > 12:
		return []
	var out: Array = []
	for index in DataLoader.wind_regions_list.size():
		var region: Dictionary = DataLoader.wind_regions_list[index]
		if region.is_empty():
			continue
		var raster_id := index + 1  # the raster palette is 1-based in file order
		var cell := _region_probe_cell(region, raster_id, layers)
		if cell.x < 0:
			# Defensive: the validator's group-9 coverage pins this unreachable.
			continue
		var token := str(layers.prevailing_for(cell, month))
		out.append({
			"region_id": raster_id,
			"id": str(region.get("id", "")),
			"cell": cell,
			"token": token,
			"variable": token == "VAR",
		})
	return out


## Probe cell of a wind region: the polygon's centroid tile when the raster
## agrees, else the first lattice hit inside the tile-space bounding box.
## `(-1, -1)` when the region owns no raster tile (never on shipped data).
static func _region_probe_cell(region: Dictionary, raster_id: int, layers) -> Vector2i:
	var polygon: Array = region.get("polygon", [])
	if polygon.size() < 3:
		return Vector2i(-1, -1)
	# Polygon vertices in tile space (the §6.1 projection, longitudes unwrapped
	# by nearest continuation — the OceanLayers ring rule — so a dateline-spanning
	# bbox stays contiguous).
	var tpd := float(OceanLayersLib.GRID_WIDTH) / 360.0
	var xs: Array[float] = []
	var ys: Array[float] = []
	var prev := 0.0
	var offset := 0.0
	var first := true
	for pair in polygon:
		var lon := float(pair[1]) + offset
		if not first:
			while lon - prev > 180.0:
				lon -= 360.0
				offset -= 360.0
			while lon - prev < -180.0:
				lon += 360.0
				offset += 360.0
		prev = lon
		first = false
		xs.append((lon + 180.0) * tpd)
		ys.append((90.0 - float(pair[0])) * tpd)
	var min_x := float(xs.min())
	var max_x := float(xs.max())
	var min_y := maxf(0.0, float(ys.min()))
	var max_y := minf(float(OceanLayersLib.GRID_HEIGHT), float(ys.max()))
	var mid := Vector2i(
		clampi(int((min_x + max_x) * 0.5), 0, OceanLayersLib.GRID_WIDTH - 1),
		clampi(int((min_y + max_y) * 0.5), 0, OceanLayersLib.GRID_HEIGHT - 1))
	if layers.wind_region_at(mid) == raster_id:
		return mid
	# Coarse lattice over the bbox, row-major, deterministic.
	var stride_x := maxf(1.0, (max_x - min_x) / float(REGION_PROBE_STEPS))
	var stride_y := maxf(1.0, (max_y - min_y) / float(REGION_PROBE_STEPS))
	var y := min_y + stride_y * 0.5
	while y < max_y:
		var x := min_x + stride_x * 0.5
		while x < max_x:
			var cell := Vector2i(
				posmod(int(x), OceanLayersLib.GRID_WIDTH),
				clampi(int(y), 0, OceanLayersLib.GRID_HEIGHT - 1))
			if layers.wind_region_at(cell) == raster_id:
				return cell
			x += stride_x
		y += stride_y
	return Vector2i(-1, -1)


## The current layer for `month` (1..12): one arrow per authored
## current-system path segment, probed at the segment midpoint (then the
## quarter/tenth points) for a raster tile that carries the current.
## Direction comes from `OceanLayers.current_at(cell, month)` — the
## **reversal-applied** vector — so a previewed summer month flips the Somali
## arrows. Returns `[{system_id, cell, dir, strength}]`. Read-only.
static func current_arrows(month: int, ocean = null) -> Array:
	var layers = ocean if ocean != null else OceanLayersLib.instance()
	if month < 1 or month > 12:
		return []
	var out: Array = []
	for system_raw in DataLoader.ocean_currents_list:
		var system: Dictionary = system_raw if system_raw is Dictionary else {}
		var path: Array = system.get("path", [])
		if path.size() < 2:
			continue
		var system_id := str(system.get("id", ""))
		for segment in path.size() - 1:
			var cell := _segment_probe_cell(path[segment], path[segment + 1],
				month, layers)
			if cell.x < 0:
				continue
			var current: Dictionary = layers.current_at(cell, month)
			if current.is_empty():
				continue
			out.append({
				"system_id": system_id,
				"cell": cell,
				"dir": str(current["dir"]),
				"strength": int(current["strength"]),
			})
	return out


## First tile of `a→b` (midpoint, then quarters, then tenths) whose decoded
## current is non-empty — the raster paints water only, so a waypoint on land
## walks to the corridor. `(-1, -1)` when no probe carries a current.
static func _segment_probe_cell(a: Array, b: Array, month: int, layers) -> Vector2i:
	var samples: Array[float] = [0.5, 0.25, 0.75, 0.1, 0.9]
	for t in samples:
		# The §6.1 projection (OceanLayers' `tile_of_latlon` — re-derived here,
		# not re-parsed, so `ocean_layers.gd` keeps its single-writer file).
		var tpd := float(OceanLayersLib.GRID_WIDTH) / 360.0
		var lat := float(a[0]) + (float(b[0]) - float(a[0])) * t
		var lon := float(a[1]) + (float(b[1]) - float(a[1])) * t
		var cell := Vector2i(
			int(floor((lon + 180.0) * tpd)) % OceanLayersLib.GRID_WIDTH,
			clampi(int(floor((90.0 - lat) * tpd)), 0, OceanLayersLib.GRID_HEIGHT - 1))
		if not layers.current_at(cell, month).is_empty():
			return cell
	return Vector2i(-1, -1)


## The ice layer for `month` (1..12): the in-month seasonal-ice tiles, sorted
## for a deterministic draw. The player layer tints **explored tiles only**;
## the omniscient debug layer ignores the bitset.
static func ice_cells(month: int, omniscient: bool, map, ocean = null) -> Array:
	var layers = ocean if ocean != null else OceanLayersLib.instance()
	var mask: Dictionary = layers.ice_mask_for(month)
	var out: Array = []
	for cell in mask:
		if not omniscient and not is_explored(cell, map):
			continue
		out.append(cell)
	out.sort()
	return out


## Every port as the omniscient chart draws it (`80-*` §4.6 debug mode):
## `[{port_id, cell (shore), berth_cell, color, neutral, capital, name}]` in
## `ports_list` order. Nation colors for sovereign ports, `PORT_NEUTRAL`
## grey for `nation_id: ""`, capitals ringed (the nations' `capital_port_id`).
static func all_port_dots(map, nations: Dictionary = {}) -> Array:
	var out: Array = []
	if map == null:
		return out
	var nation_table: Dictionary = nations if not nations.is_empty() \
		else DataLoader.nations
	var capitals := nation_capitals()
	for port_raw in DataLoader.ports_list:
		var port: Dictionary = port_raw if port_raw is Dictionary else {}
		var port_id := str(port.get("id", ""))
		if port_id.is_empty():
			continue
		var berth: Vector2i = map.port_cell(port_id)
		if berth.x < 0:
			continue
		var cell: Vector2i = map.shore_cell(port_id)
		if cell.x < 0:
			# A berth with no shore tile is a data error (validator group 6);
			# the chart still marks the water access point.
			cell = berth
		var nation_id := str(port.get("nation_id", ""))
		out.append({
			"port_id": port_id,
			"cell": cell,
			"berth_cell": berth,
			"color": port_neutral_color() if nation_id.is_empty()
				else _nation_color(nation_id, nation_table),
			"neutral": nation_id.is_empty(),
			"capital": str(capitals.get(port_id, "")),
			"name": _port_name(port),
		})
	return out


## `port_id → nation_id` for every nation's `capital_port_id` (the ring set).
static func nation_capitals() -> Dictionary:
	var out: Dictionary = {}
	for entry in DataLoader.nations_list:
		if entry is Dictionary:
			var capital := str((entry as Dictionary).get("capital_port_id", ""))
			if not capital.is_empty():
				out[capital] = str((entry as Dictionary).get("id", ""))
	return out


# --- Phase-6 debug network (`80-*` §4.6, IMPLEMENT-Phase6.md §2.12) ---------

## Per-lane legend color: a **stable hue rotation** over the built lane count.
## (The doc pins "per-lane colors — a stable palette rotation" without pinning
## the table; the rotation is deterministic in lane-id order and presentation
## only, `80-*` §4.8 placeholder rules.)
static func lane_color(index: int, count: int) -> Color:
	var step := 360.0 / float(maxi(count, 1))
	return Color.from_hsv(fposmod(float(index) * step, 360.0) / 360.0, 0.72, 0.95)


## The built tile path of a lane for `month`: the variant whose `months`
## window contains the month, else the base path (`10-*` §4.14 variant rule).
## `{path: Array[Vector2i], variant: String}` — `variant` is "" for the base.
static func active_lane_path(lane: Dictionary, month: int) -> Dictionary:
	var chosen: Array = lane.get("tile_path", [])
	var chosen_id := ""
	for variant_raw in lane.get("variants", []):
		var variant: Dictionary = variant_raw if variant_raw is Dictionary else {}
		if month in (variant as Dictionary).get("months", []):
			chosen = (variant as Dictionary).get("tile_path", chosen)
			chosen_id = str((variant as Dictionary).get("id", ""))
			break
	var path: Array = []
	for tile in chosen:
		if tile is Array and (tile as Array).size() >= 2:
			path.append(Vector2i(int(tile[0]), int(tile[1])))
	return {"path": path, "variant": chosen_id}


## The whole network layer for `month`: the 17 built lanes (active path solid
## + inactive variants for the side legend), the port spokes, and the
## chokepoint diamonds. **Chokepoint derivation:** the builder reports the
## network's junction tiles (`trade_routes_built.json` `junctions` — tiles
## shared by ≥ 2 distinct paths), the same set the raiders camp near
## (`npc_fleets.gd` `_anchor_tiles`: "Junction tiles … the network's
## chokepoints"). Contiguous shared tiles (8-connected, wrap-aware) collapse
## to one diamond at the cluster centroid, attributed to every lane through
## it. All read-only; lane ids sorted for determinism.
static func lane_network(month: int) -> Dictionary:
	var lane_ids: Array = DataLoader.route_lanes.keys()
	lane_ids.sort()
	var lanes: Array = []
	var tile_lanes: Dictionary = {}
	for index in lane_ids.size():
		var lane: Dictionary = DataLoader.route_lanes[lane_ids[index]]
		var active := active_lane_path(lane, month)
		var inactive: Array = []
		for variant_raw in lane.get("variants", []):
			var variant: Dictionary = variant_raw if variant_raw is Dictionary else {}
			var variant_id := str((variant as Dictionary).get("id", ""))
			if variant_id == str(active.get("variant", "")):
				continue
			var path: Array = []
			for tile in (variant as Dictionary).get("tile_path", []):
				if tile is Array and (tile as Array).size() >= 2:
					path.append(Vector2i(int(tile[0]), int(tile[1])))
			inactive.append({"id": variant_id, "path": path})
		lanes.append({
			"id": str(lane.get("id", "")),
			"color": lane_color(index, lane_ids.size()),
			"active_path": active.get("path", []),
			"active_variant": str(active.get("variant", "")),
			"inactive_paths": inactive,
		})
		for tile in active.get("path", []):
			_note_tile_lanes(tile_lanes, tile, str(lane.get("id", "")))
	var spokes: Array = []
	for port_id in DataLoader.route_spokes:
		var spoke: Dictionary = DataLoader.route_spokes[port_id]
		var path: Array = []
		for tile in spoke.get("tile_path", []):
			if tile is Array and (tile as Array).size() >= 2:
				path.append(Vector2i(int(tile[0]), int(tile[1])))
		spokes.append({"port": str(port_id), "path": path})
	spokes.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return str(a.get("port", "")) < str(b.get("port", "")))
	return {
		"lanes": lanes,
		"spokes": spokes,
		"chokepoints": _chokepoint_cells(tile_lanes),
	}


static func _note_tile_lanes(tile_lanes: Dictionary, tile: Vector2i,
		lane_id: String) -> void:
	var key := Vector2i(posmod(tile.x, OceanLayersLib.GRID_WIDTH), tile.y)
	if not tile_lanes.has(key):
		tile_lanes[key] = [lane_id]
		return
	var lanes: Array = tile_lanes[key]
	if not lanes.has(lane_id):
		lanes.append(lane_id)


## Contiguous clusters (8-connected, wrap-aware on x) of tiles shared by ≥ 2
## lanes → one diamond per cluster at its centroid, lanes sorted.
static func _chokepoint_cells(tile_lanes: Dictionary) -> Array:
	var shared: Array = []
	for key in tile_lanes:
		if (tile_lanes[key] as Array).size() >= 2:
			shared.append(key)
	shared.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
		if a.y != b.y:
			return a.y < b.y
		return a.x < b.x)
	var visited: Dictionary = {}
	var out: Array = []
	for seed in shared:
		if visited.has(seed):
			continue
		var stack: Array = [seed]
		visited[seed] = true
		var members: Array = []
		while not stack.is_empty():
			var tile: Vector2i = stack.pop_back()
			members.append(tile)
			for dy in range(-1, 2):
				for dx in range(-1, 2):
					var neighbour := Vector2i(
						posmod(tile.x + dx, OceanLayersLib.GRID_WIDTH), tile.y + dy)
					if visited.has(neighbour) or not tile_lanes.has(neighbour):
						continue
					if (tile_lanes[neighbour] as Array).size() < 2:
						continue
					visited[neighbour] = true
					stack.append(neighbour)
		# Centroid, x-unwrapped relative to the seed so a seam-hugging cluster
		# cannot skew halfway around the world.
		var lanes: Array = (tile_lanes[seed] as Array).duplicate()
		var sum_x := 0
		var sum_y := 0
		for tile: Vector2i in members:
			var ux := tile.x
			while ux - seed.x > OceanLayersLib.GRID_WIDTH / 2.0:
				ux -= OceanLayersLib.GRID_WIDTH
			while ux - seed.x < -OceanLayersLib.GRID_WIDTH / 2.0:
				ux += OceanLayersLib.GRID_WIDTH
			sum_x += ux
			sum_y += tile.y
		lanes.sort()
		out.append({
			"cell": Vector2i(
				posmod(sum_x / members.size(), OceanLayersLib.GRID_WIDTH),
				sum_y / members.size()),
			"lanes": lanes,
		})
	return out


# --- Phase-6 debug ecology (`80-*` §4.6, §4.5.2) ----------------------------

## Every live fleet via `NpcFleets.markers()` — the only fleet source, the
## same dicts the world scene renders, never culled on the debug chart and
## **never ticked** from here (read-only observer; `sim` may be null, then no
## markers are reported).
static func fleet_markers(sim) -> Array:
	if sim == null or not sim.has_method("markers"):
		return []
	return sim.markers()


## The wreck sites (`GameState.wrecks`), `[{id, cell}]` in payload order.
static func wreck_cells() -> Array:
	var out: Array = []
	for wreck in GameState.wrecks:
		if not (wreck is Dictionary):
			continue
		var pos = (wreck as Dictionary).get("cell", {})
		if pos is Dictionary:
			out.append({
				"id": str((wreck as Dictionary).get("id", "")),
				"cell": Vector2i(int((pos as Dictionary).get("x", 0)),
					int((pos as Dictionary).get("y", 0))),
			})
	return out


## The hunter-intel markers (`60-*` §4.11.11.1): the ring on the last
## departed port's shore tile and the cross on the at-sea intel cell —
## `[{kind, cell, port_id}]`, both fields read guard-style from the world
## block (`world.last_departed_port`, `world.hunter_intel_cell`).
static func intel_markers(map) -> Array:
	var out: Array = []
	var port_id := str(GameState.world.get("last_departed_port", ""))
	if not port_id.is_empty() and map != null:
		var cell: Vector2i = map.shore_cell(port_id)
		if cell.x < 0:
			cell = map.port_cell(port_id)
		if cell.x >= 0:
			out.append({"kind": "ring", "cell": cell, "port_id": port_id})
	var cell_value = GameState.world.get("hunter_intel_cell", null)
	if cell_value is Dictionary:
		out.append({
			"kind": "cross",
			"cell": Vector2i(int((cell_value as Dictionary).get("x", 0)),
				int((cell_value as Dictionary).get("y", 0))),
			"port_id": "",
		})
	elif cell_value is Vector2i:
		out.append({"kind": "cross", "cell": cell_value, "port_id": ""})
	return out


## Splits a wrapped tile path into straight runs (a run break wherever one
## step would jump more than half the world — the antimeridian, or a data
## gap), so the chart's polylines never draw a lane across the whole map.
## Tile space; the screen conversion is the scene's.
static func path_runs(path: Array, width: int) -> Array:
	var runs: Array = []
	var run: Array = []
	var half := float(maxi(width, 1)) / 2.0
	for tile in path:
		if run.is_empty():
			run.append(tile)
			continue
		var prev: Vector2i = run[run.size() - 1]
		if absf(float(tile.x) - float(prev.x)) > half or absi(tile.y - prev.y) > 1:
			runs.append(run)
			run = [tile]
		else:
			run.append(tile)
	if not run.is_empty():
		runs.append(run)
	return runs
