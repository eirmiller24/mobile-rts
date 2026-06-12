class_name DesignationChips
extends Control
## Labeled chips along the top edge, one per designation (design_m3.md
## §6.1): tap a group chip to reselect it, tap a location chip to jump the
## camera there. Chip *meaning* comes from the designations store; only
## the rendering lives here. Renaming/deleting is the Organize tab's job
## (deferred).

signal chip_tapped(slot: int)

const CHIP_H := 34.0

var designations: Designations

var _row: HBoxContainer


func _ready() -> void:
	_row = HBoxContainer.new()
	_row.add_theme_constant_override("separation", 6)
	add_child(_row)
	anchor_left = 0.5
	anchor_right = 0.5
	anchor_top = 0.0
	anchor_bottom = 0.0
	designations.changed.connect(_rebuild)
	_rebuild()


func _rebuild() -> void:
	for child in _row.get_children():
		child.queue_free()
	for o: Dictionary in designations.occupied():
		var e: Dictionary = o["entry"]
		var chip := Button.new()
		chip.custom_minimum_size = Vector2(0, CHIP_H)
		chip.text = e["name"] if e["kind"] == "location" \
				else "%s (%d)" % [e["name"], e["ids"].size()]
		chip.add_theme_color_override("font_color",
				Color(0.8, 1.0, 0.85) if e["kind"] == "group" else Color(1.0, 0.9, 0.7))
		chip.pressed.connect(func() -> void: chip_tapped.emit(o["slot"]))
		_row.add_child(chip)
	# Re-center under the top edge once sized.
	await get_tree().process_frame
	if is_instance_valid(_row):
		offset_left = -_row.size.x / 2.0
		offset_right = _row.size.x / 2.0
