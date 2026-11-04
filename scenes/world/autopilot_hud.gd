extends PanelContainer
## Appointed-voyage HUD bar — docs/80-UI-UX.md §4.10.4 + §4.5 ("instanced
## into the world HUD below the top bar"), docs/20-WORLD-AND-SAILING.md
## §4.19. Reads `player.autopilot` + the runtime route; **mutates nothing**
## except its own visibility and the one action the bar owns — the cancel
## button, which is a manual cancel (`Autopilot.cancel("manual")`, §4.19
## "any manual input cancels").
##
## ```
## +--------------------------------------------------------------+
## | 目的地 {port} · 预计 {days} 天                        [取消委任] |  36px
## +--------------------------------------------------------------+
## ```
##
## Strings: `sail.autopilot.hud.bar` / `sail.autopilot.cancel`
## (docs/80-* §4.15 family). Hidden while no appointment stands; visible +
## refreshed on open/`day_advanced`. The instancing into the world HUD is the
## master's micro-ledger entry — the host calls [method setup] after adding
## the scene, everything else is self-contained.
##
## Placeholder art rule: palette colors + default font only (§4.8, via
## `scripts/palette.gd`).

const AutopilotLib := preload("res://scripts/world/autopilot.gd")

## `sail.autopilot.*` keys (docs/80-* §4.15).
const KEY_HUD_BAR := "sail.autopilot.hud.bar"
const KEY_CANCEL := "sail.autopilot.cancel"

@onready var _info: Label = $Row/Info
@onready var _cancel: Button = $Row/Cancel

## True once [method setup] wired the signals (idempotent re-setup).
var _wired := false


func _ready() -> void:
	# Phase-10 sweep: the bar's panel chrome retired to the theme (§4.9
	# PanelContainer row); the info line reads in the theme's Label ink.
	_info.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_cancel.text = I18n.t_key(KEY_CANCEL)
	_cancel.pressed.connect(_on_cancel_pressed)
	visible = false
	_rebind_labels()


## The world-HUD wiring seam (the master's micro): connect the shared
## signals + take the first read. Idempotent; safe to call again after a
## re-parent.
func setup() -> void:
	if not _wired:
		EventBus.day_advanced.connect(_on_day_advanced)
		EventBus.locale_changed.connect(_on_locale_changed)
		_wired = true
	refresh()


## True while the bar is on screen (an appointment stands).
func is_showing() -> bool:
	return visible


## Re-reads `player.autopilot` + the route: visibility follows the
## appointment, the label shows `sail.autopilot.hud.bar` with the localized
## destination name and the closed-form ETA in whole days (ceiling — the
## walk pays per-tile fractions, the bar advertises the day count). Not
## appointed → hidden, no reads.
func refresh() -> void:
	if not AutopilotLib.appointed():
		visible = false
		return
	var dest_port_id := AutopilotLib.dest_port_id()
	var port: Dictionary = DataLoader.get_port(dest_port_id)
	var port_name := str(dest_port_id)
	if not port.is_empty():
		port_name = I18n.t(port.get("name", {}))
	var steps := AutopilotLib.route()
	var days := ceili(AutopilotLib.eta_days(steps)) if not steps.is_empty() \
		else 0
	_info.text = I18n.fmt(KEY_HUD_BAR, {"port": port_name, "days": days})
	visible = true


# --- Actions / signals -------------------------------------------------------

## The bar's one action: a manual cancel (§4.19 "any manual input cancels";
## §4.10.4 "Cancel returns control immediately; no clock cost"). The world's
## movement seam clears its walk order on the same player.autopilot read.
func _on_cancel_pressed() -> void:
	AutopilotLib.cancel(AutopilotLib.REASON_MANUAL)
	refresh()


func _on_day_advanced(_new_day: int) -> void:
	refresh()


func _on_locale_changed(_locale: String) -> void:
	_rebind_labels()
	refresh()


func _rebind_labels() -> void:
	_cancel.text = I18n.t_key(KEY_CANCEL)
