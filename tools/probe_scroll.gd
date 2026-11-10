extends Node
## Temporary probe: the sandbox rows scrolls' live rects.

const RegistryLib := preload("res://scripts/ui/layout_registry.gd")
const FleetLib := preload("res://scripts/fleet/fleet.gd")
const Scene := preload("res://scenes/combat/battle_sandbox.tscn")


func _ready() -> void:
	GameState.player = {
		"nation_id": "portugal",
		"stats": {"leadership": 10, "seamanship": 10, "combat": 10,
			"navigation": 10, "luck": 10},
		"xp": 0, "level": 1, "officers": [], "reputation": {},
	}
	GameState.fleet = [FleetLib.new_ship("caravel", 0)]
	GameState.day = 1
	GameState.gold = 10000
	GameState.morale = 70
	GameState.current_port = ""
	GameState.npc_fleets = []
	var host := Control.new()
	host.size = Vector2(1920, 1088)
	add_child(host)
	var screen: Control = Scene.instantiate()
	host.add_child(screen)
	for i in range(8):
		await get_tree().process_frame
	for id in ["player_panel", "player_panel.rows", "player_rows.0",
			"enemy_panel", "enemy_panel.rows", "enemy_rows.0"]:
		var rec: Dictionary = RegistryLib._screens.get("sandbox", {}) \
				.get(id, {})
		var ref: WeakRef = rec.get("control", null) if rec.has("control") \
				else null
		var ctl: Control = ref.get_ref() if ref != null else null
		if ctl == null:
			print("PROBE %s: DEAD" % id)
			continue
		print("PROBE %s: pos=%s size=%s gpos=%s parent=%s scroll=%s"
				% [id, str(ctl.position), str(ctl.size), str(ctl.global_position),
				ctl.get_parent().name, str(ctl is ScrollContainer)])
	get_tree().quit(0)
