extends Node
## I18n — locale lookup for every player-facing string
## (docs/90-ARCHITECTURE.md §5.3, conventions in docs/80-UI-UX.md §4.4).
##
## All display text lives in data/*.json as `{"zh": "...", "en": "..."}`.
## There is no fallback chain: the validator guarantees both locales, so a
## missing one is a bug and returns "<missing>" after logging (never blank).
##
## Autoload #3, between DataLoader (#2) and GameState (#4). `_ready` is
## deliberately inert so a partial autoload set cannot crash the script.

const LOCALES: Array[String] = ["zh", "en"]


func _ready() -> void:
	pass


## Locale currently in effect; falls back to "en" if GameState is absent.
func get_locale() -> String:
	var state := _state()
	if state == null:
		return "en"
	var value = state.get("locale")
	if value is String and (value as String) in LOCALES:
		return value
	return "en"


## Translate an L10nString. Requested locale if present and non-empty, else
## log the bug and return "<missing>".
func t(l10n: Dictionary) -> String:
	var locale := get_locale()
	var text = l10n.get(locale, null)
	if text is String and not (text as String).is_empty():
		return text
	push_error("I18n: missing '%s' locale in L10nString %s" % [locale, l10n])
	return "<missing>"


## Translate a ui_strings.json key. A missing key renders the literal
## "<key>" and logs an error (done-when behaviour, docs/80-* §6).
func t_key(key: String) -> String:
	var l10n: Dictionary = DataLoader.ui_strings.get(key, {})
	if l10n.is_empty():
		push_error("I18n: unknown ui_strings key '%s'" % key)
		return "<%s>" % key
	return t(l10n)


## t_key() plus `{name}` substitution for each entry in `values`
## (placeholder syntax: docs/80-* §4.4).
func fmt(key: String, values: Dictionary = {}) -> String:
	var text := t_key(key)
	for name in values:
		text = text.replace("{%s}" % name, str(values[name]))
	return text


## Validates and stores the locale, then announces the change. Invalid values
## are ignored with a logged error.
func set_locale(locale: String) -> void:
	if not (locale in LOCALES):
		push_error("I18n: invalid locale '%s' (expected zh or en)" % locale)
		return
	var state := _state()
	if state == null:
		push_error("I18n: GameState is unavailable; cannot set locale '%s'" % locale)
		return
	state.set("locale", locale)
	EventBus.locale_changed.emit(locale)


## Convenience zh↔en toggle (the `L` key, docs/80-* §4.3).
func toggle_locale() -> void:
	set_locale("zh" if get_locale() == "en" else "en")


func _state() -> Node:
	# Autoload order guarantees GameState exists by the time UI calls us; the
	# lookup is by name so this script also survives a partial autoload set
	# (e.g. a headless tool script loading only DataLoader).
	var tree := get_tree()
	if tree == null:
		return null
	var node := tree.root.get_node_or_null("GameState")
	return node
