class_name MapSelect
extends CanvasLayer
## Pre-match map picker. Lists the maps under res://maps/ — single-file JSON maps
## (design_m3.md §3) and bundle directories (design_m5.md §4.1) alike — and emits
## the chosen path. Purely view-side; it touches no sim state. The game root
## loads the pick and proceeds to faction select (skirmish maps) or straight into
## the match (scenario maps with no start anchors).

signal map_chosen(path: String)

const MAPS_DIR := "res://maps/"


## [{ path: String, name: String, kind: "map"|"bundle" }], sorted by name.
static func discover() -> Array:
	var out: Array = []
	var d := DirAccess.open(MAPS_DIR)
	if d == null:
		return out
	for f: String in d.get_files():
		if f.to_lower().ends_with(".json"):
			out.append({"path": MAPS_DIR + f, "name": _name_of(MAPS_DIR + f), "kind": "map"})
	for sub: String in d.get_directories():
		var manifest := MAPS_DIR + sub + "/manifest.json"
		if FileAccess.file_exists(manifest):
			out.append({"path": MAPS_DIR + sub, "name": _name_of(manifest), "kind": "bundle"})
	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a["name"] < b["name"])
	return out


## Cheap display name from a manifest/map JSON without a full compile.
static func _name_of(json_path: String) -> String:
	var text := FileAccess.get_file_as_string(json_path)
	var data: Variant = JSON.parse_string(text)
	if typeof(data) == TYPE_DICTIONARY:
		var d: Dictionary = data
		if d.has("name"):
			return str(d["name"])
		if d.has("manifest") and typeof(d["manifest"]) == TYPE_DICTIONARY:
			return str((d["manifest"] as Dictionary).get("name", json_path.get_file()))
	return json_path.get_file()


func setup() -> void:
	layer = 80
	var dim := ColorRect.new()
	dim.color = Color(0.04, 0.05, 0.07, 0.96)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(dim)

	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(center)

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 16)
	center.add_child(box)

	var title := Label.new()
	title.text = "Select Map"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 36)
	box.add_child(title)

	for entry: Dictionary in discover():
		box.add_child(_build_row(entry))


func _build_row(entry: Dictionary) -> Control:
	var btn := Button.new()
	var tag := "  [scenario]" if entry["kind"] == "bundle" else ""
	btn.text = "%s%s" % [entry["name"], tag]
	btn.custom_minimum_size = Vector2(360, 60)
	btn.add_theme_font_size_override("font_size", 24)
	var path: String = entry["path"]
	btn.pressed.connect(func() -> void:
		map_chosen.emit(path)
		queue_free())
	return btn
