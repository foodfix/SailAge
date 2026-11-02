extends Node
## GameOverHost — full-scene S9 coverage (80-* §4.2 full-scene amendment,
## 2026-11-02; docs/90-* §5.1 event contract).
##
## A run can die on any ledger tick, port day-rolls included (`20-*` §4.9):
## the classic case was a starvation/scurvy counter completing on the midnight
## crossing of a docked wait — the engine froze the clock and every port-side
## screen stayed up with no explanation, because S9 was only wired into the
## world scene (and the battle screen). Every run-hosting scene now attaches
## one of these hosts in `_ready`:
##
##     GameOverHostLib.attach_to(self)
##
## and the host owns the port-side S9: on `EventBus.game_over` it builds a
## topmost `CanvasLayer` (layer 3, the world scene's own convention) with the
## shared `gameover_screen.tscn` and hands it the reason. The world scene
## keeps its own handler (`world_map.gd` — it clears queued reports and owns
## the debug-chart layer placement); a host never attaches there.
##
## * Nothing here reads run state — the screen routes on any key/button and
##   touches no save (`20-*` §4.9).
## * The open screen joins the `modal_overlay` group (`90-*` §11), so every
##   host scene's `has_modal()` sees it and holds its own hotkeys.
## * Pure wiring, no i18n: all strings come from `gameover_screen.gd`.

const GameOverScene := preload("res://scenes/ui_shared/gameover_screen.tscn")

## Above the HUD (layer 1) and the error overlay (layer 2) — the world
## scene's `GameOverLayer` convention, mirrored here.
const LAYER := 3

## The S9 currently up under this host (null while the run is alive).
var _screen: Control = null


func _ready() -> void:
	EventBus.game_over.connect(_on_game_over)


## Raises S9 for `reason` — once per host (the signal fires exactly once per
## run; the guard also makes repeated emissions harmless).
func _on_game_over(reason: String) -> void:
	if _screen != null:
		return
	var layer := CanvasLayer.new()
	layer.name = "GameOverLayer"
	layer.layer = LAYER
	add_child(layer)
	_screen = GameOverScene.instantiate()
	_screen.name = "GameOverScreen"
	layer.add_child(_screen)
	_screen.open_reason(reason)


## True while this host's S9 is on screen (tests / hosts).
func is_open() -> bool:
	return _screen != null and _screen.is_open()


## Creates (or returns the existing) host under `host` — the shared attach
## seam every run-hosting scene calls in `_ready`. Idempotent per host.
static func attach_to(host: Node) -> Node:
	if host == null:
		return null
	var existing := host.get_node_or_null("GameOverHost")
	if existing != null:
		return existing
	var node: Node = load("res://scenes/ui_shared/game_over_host.gd").new()
	node.name = "GameOverHost"
	host.add_child(node)
	return node
