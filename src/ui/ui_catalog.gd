class_name UICatalog
extends RefCounted
## Loads UI definitions from data (see design.md "UI as Data"). The in-game
## UI is instantiated from these defs; nothing in a scene or script literal
## binds a button to a command. Maps will eventually override this catalog
## through the same mechanism unit/ability catalogs use.


class CommandDef:
	var id: String
	var label: String
	var color: Color
	## Targeted commands wait for an object tap after being chosen;
	## untargeted ones (stop, hold) execute on the selection immediately.
	var targeted := true


class ButtonDef:
	var id: String
	var default_command: String
	## direction ("up"/"right"/"down"/"left") -> command id
	var radial: Dictionary = {}
	## When true, the engine fills this button's radial from the current
	## selection's catalog abilities (design_m3.md §6.7). The *mechanic*
	## is engine code; that this button hosts it is data.
	var selection_abilities := false


class TabDef:
	var id: String
	var label: String
	var screen: String


class ScreenDef:
	var id: String
	var title: String
	var widgets: Array[WidgetDef] = []


class WidgetDef:
	## See WIDGET_TYPES; new widget types are added there and in the
	## console's widget builder, never as bespoke scenes.
	var type: String
	var label: String
	## "none", or "screen:<id>" to navigate within the console.
	var action := "none"
	## Type-specific parameters (e.g. minimap mode, placement screen id).
	var params: Dictionary = {}


const WIDGET_TYPES := ["button", "label", "structure_grid", "unit_grid",
		"queue_strip", "alloc_sliders", "minimap", "group_roster",
		"worker_dials", "stance_picker"]


## command id -> CommandDef
var commands: Dictionary = {}
var side_buttons: Array[ButtonDef] = []
## context kind ("ground"/"enemy"/"resource") -> command id
var context_orders: Dictionary = {}
var reselect_label := "Re"
var reselect_hold_time := 0.5
var console_tabs: Array[TabDef] = []
## screen id -> ScreenDef
var console_screens: Dictionary = {}
## HUD resource readout labels (faction-skinnable: Bandwidth is Hive
## naming, M4's Crew reuses the slot).
var hud_labels: Dictionary = {"alloy": "Alloy", "flux": "Flux",
		"bandwidth": "Bandwidth"}


static func load_default() -> UICatalog:
	return load_from_json("res://data/ui/default_ui.json")


## Faction/map override (design.md "UI as Data", design_m4.md §13.2): later
## layers patch earlier ones per leaf key, the same merge the object catalog
## uses. The Rebel UI is `[default_ui.json, rebels_ui.json]`.
static func load_layers(paths: Array) -> UICatalog:
	var merged := {}
	for path: String in paths:
		var text := FileAccess.get_file_as_string(path)
		if text.is_empty():
			push_error("UICatalog: cannot read %s" % path)
			return null
		var data: Variant = JSON.parse_string(text)
		if data == null or typeof(data) != TYPE_DICTIONARY:
			push_error("UICatalog: %s is not valid JSON" % path)
			return null
		_deep_merge(merged, data)
	return _build(merged)


## Merge b into a per leaf key: nested dicts recurse, everything else
## (including arrays — a layer replaces a whole list) overwrites.
static func _deep_merge(a: Dictionary, b: Dictionary) -> void:
	for k: Variant in b:
		if a.has(k) and typeof(a[k]) == TYPE_DICTIONARY \
				and typeof(b[k]) == TYPE_DICTIONARY:
			_deep_merge(a[k], b[k])
		else:
			a[k] = b[k]


static func load_from_json(path: String) -> UICatalog:
	return load_layers([path])


static func _build(data: Dictionary) -> UICatalog:
	var catalog := UICatalog.new()
	for id in data.get("commands", {}):
		var raw: Dictionary = data["commands"][id]
		var cmd := CommandDef.new()
		cmd.id = id
		cmd.label = raw.get("label", id)
		cmd.color = Color(raw.get("color", "ffffff"))
		cmd.targeted = raw.get("targeted", true)
		catalog.commands[id] = cmd
	for raw in data.get("side_buttons", []):
		var btn := ButtonDef.new()
		btn.id = raw.get("id", "")
		btn.default_command = raw.get("default_command", "")
		btn.radial = raw.get("radial", {})
		btn.selection_abilities = raw.get("selection_abilities", false)
		catalog.side_buttons.append(btn)
	catalog.context_orders = data.get("context_orders", {})
	var reselect: Dictionary = data.get("reselect", {})
	catalog.reselect_label = reselect.get("label", "Re")
	catalog.reselect_hold_time = reselect.get("hold_time", 0.5)
	var console: Dictionary = data.get("console", {})
	for raw in console.get("tabs", []):
		var tab := TabDef.new()
		tab.id = raw.get("id", "")
		tab.label = raw.get("label", tab.id)
		tab.screen = raw.get("screen", "")
		catalog.console_tabs.append(tab)
	for screen_id in console.get("screens", {}):
		var raw: Dictionary = console["screens"][screen_id]
		var screen := ScreenDef.new()
		screen.id = screen_id
		screen.title = raw.get("title", screen_id)
		for raw_widget in raw.get("widgets", []):
			var widget := WidgetDef.new()
			widget.type = raw_widget.get("type", "label")
			widget.label = raw_widget.get("label", "")
			widget.action = raw_widget.get("action", "none")
			widget.params = raw_widget.get("params", {})
			screen.widgets.append(widget)
		catalog.console_screens[screen_id] = screen
	var hud: Dictionary = data.get("hud", {})
	for key in catalog.hud_labels.keys():
		if hud.has(key):
			catalog.hud_labels[key] = hud[key]
	return catalog


func command(id: String) -> CommandDef:
	return commands.get(id)


## Returns a list of problems; empty means the catalog is usable.
func validate() -> PackedStringArray:
	var errors := PackedStringArray()
	if side_buttons.is_empty():
		errors.append("no side buttons defined")
	for btn in side_buttons:
		if btn.id.is_empty():
			errors.append("side button with empty id")
		if not commands.has(btn.default_command):
			errors.append("button '%s': unknown default command '%s'"
					% [btn.id, btn.default_command])
		for dir in btn.radial:
			if dir not in ["up", "right", "down", "left"]:
				errors.append("button '%s': bad radial direction '%s'"
						% [btn.id, dir])
			if not commands.has(btn.radial[dir]):
				errors.append("button '%s': unknown radial command '%s'"
						% [btn.id, btn.radial[dir]])
	for kind in ["ground", "enemy", "resource"]:
		if not context_orders.has(kind):
			errors.append("missing context order for '%s'" % kind)
		elif not commands.has(context_orders[kind]):
			errors.append("context order '%s': unknown command '%s'"
					% [kind, context_orders[kind]])
	for tab in console_tabs:
		if tab.id.is_empty():
			errors.append("console tab with empty id")
		if not console_screens.has(tab.screen):
			errors.append("console tab '%s': unknown screen '%s'"
					% [tab.id, tab.screen])
	for screen_id in console_screens:
		var screen: ScreenDef = console_screens[screen_id]
		for widget in screen.widgets:
			if widget.type not in WIDGET_TYPES:
				errors.append("screen '%s': unknown widget type '%s'"
						% [screen_id, widget.type])
			if widget.action.begins_with("screen:"):
				var target := widget.action.trim_prefix("screen:")
				if not console_screens.has(target):
					errors.append("screen '%s': link to unknown screen '%s'"
							% [screen_id, target])
			if widget.type == "minimap" \
					and widget.params.get("mode", "jump") not in ["jump", "pick"]:
				errors.append("screen '%s': bad minimap mode '%s'"
						% [screen_id, widget.params.get("mode")])
			if widget.type == "structure_grid":
				var place: String = widget.params.get("placement_screen", "")
				if place.is_empty() or not console_screens.has(place):
					errors.append("screen '%s': structure_grid needs a valid placement_screen"
							% screen_id)
	return errors
