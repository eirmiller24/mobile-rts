class_name DesignationChips
extends Control
## Control-group chips along the top edge (design_m3.md §6.1): tap one to
## reselect that group, or hold the control button and tap to overwrite the
## group with the current selection (design.md "The control button").
## Locations are NOT shown here — they live behind the Locations dropdown.
##
## Input is handled raw in `_input`, NOT through child Buttons: a chip tap is
## frequently the *second* finger down (the first is holding the control
## button), and Godot only emulates the primary touch to a mouse — a plain
## Button would never see it. So we hit-test touches/clicks ourselves, exactly
## as the viewport does for its secondary-touch gestures. Chip *meaning* comes
## from the designations store; only rendering + hit-testing live here.

signal chip_tapped(slot: int)

const CHIP_H := 48.0
const CHIP_FONT := 18
const CHIP_PAD := 28.0
const CHIP_GAP := 6.0
const MIN_W := 96.0

var designations: Designations

## [{slot:int, label:String, rect:Rect2}] — rects are local to this control.
var _chips: Array = []
## Single tracked press: -2 idle, -1 mouse, >=0 a touch index. One at a time
## (a chip tap is never a multi-chip gesture), which also dedups the duplicate
## events that touch<->mouse emulation produces — whichever fires first wins.
var _grab := -2
var _grab_chip := -1
## chip index currently showing a pressed highlight, or -1.
var _pressed_idx := -1


func _ready() -> void:
	# We read raw input ourselves; don't grab GUI focus from chips' rects.
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	anchor_left = 0.5
	anchor_right = 0.5
	anchor_top = 0.0
	anchor_bottom = 0.0
	designations.changed.connect(_rebuild)
	_rebuild()


func _rebuild() -> void:
	_chips.clear()
	_grab = -2
	_grab_chip = -1
	_pressed_idx = -1
	var font := ThemeDB.fallback_font
	var x := 0.0
	for o: Dictionary in designations.occupied():
		var e: Dictionary = o["entry"]
		if e["kind"] != "group":
			continue # locations live behind the Locations dropdown button
		var label := "%s (%d)" % [e["name"], e["ids"].size()]
		var tw := font.get_string_size(label, HORIZONTAL_ALIGNMENT_LEFT,
				-1, CHIP_FONT).x
		var w := maxf(MIN_W, tw + CHIP_PAD)
		_chips.append({"slot": o["slot"], "label": label,
				"rect": Rect2(x, 0.0, w, CHIP_H)})
		x += w + CHIP_GAP
	# Center the row of chips under the top edge.
	var total := maxf(0.0, x - CHIP_GAP)
	offset_left = -total / 2.0
	offset_right = total / 2.0
	queue_redraw()


func _input(event: InputEvent) -> void:
	if event is InputEventScreenTouch:
		if event.pressed:
			_begin_press(event.index, event.position)
		else:
			_end_press(event.index, event.position)
	elif event is InputEventMouseButton \
			and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			_begin_press(-1, event.position)
		else:
			_end_press(-1, event.position)


func _begin_press(pointer: int, at: Vector2) -> void:
	if _chip_at(at) == -1:
		return
	get_viewport().set_input_as_handled() # ours — keep it off the viewport
	if _grab != -2:
		return # already tracking a press; ignore the emulation duplicate
	_grab = pointer
	_grab_chip = _chip_at(at)
	_pressed_idx = _grab_chip
	queue_redraw()


func _end_press(pointer: int, at: Vector2) -> void:
	if _grab != pointer:
		if _chip_at(at) != -1:
			get_viewport().set_input_as_handled() # swallow duplicate release
		return
	var idx := _grab_chip
	_grab = -2
	_grab_chip = -1
	_pressed_idx = -1
	queue_redraw()
	if _chip_at(at) == idx:
		chip_tapped.emit(_chips[idx]["slot"])
	get_viewport().set_input_as_handled()


## Index of the chip whose global rect contains `point` (viewport coords), or
## -1. `point` and `get_global_rect()` share the (untransformed) canvas space.
func _chip_at(point: Vector2) -> int:
	for i in _chips.size():
		var r: Rect2 = _chips[i]["rect"]
		if Rect2(global_position + r.position, r.size).has_point(point):
			return i
	return -1


func _draw() -> void:
	var font := ThemeDB.fallback_font
	for i in _chips.size():
		var r: Rect2 = _chips[i]["rect"]
		var sb := StyleBoxFlat.new()
		sb.bg_color = Color(0.16, 0.22, 0.19, 0.92)
		if i == _pressed_idx:
			sb.bg_color = sb.bg_color.lightened(0.15)
		sb.set_corner_radius_all(8)
		sb.border_width_bottom = 2
		sb.border_width_top = 2
		sb.border_width_left = 2
		sb.border_width_right = 2
		sb.border_color = Color(1, 1, 1, 0.25)
		draw_style_box(sb, r)
		var label: String = _chips[i]["label"]
		var tw := font.get_string_size(label, HORIZONTAL_ALIGNMENT_LEFT,
				-1, CHIP_FONT).x
		draw_string(font, r.position + Vector2((r.size.x - tw) / 2.0,
				r.size.y / 2.0 + CHIP_FONT * 0.35), label,
				HORIZONTAL_ALIGNMENT_LEFT, -1, CHIP_FONT, Color(0.8, 1.0, 0.85))


## True when a point lands on any chip — the HUD uses this so chip taps don't
## fall through to the viewport.
func covers_point(point: Vector2) -> bool:
	return _chip_at(point) != -1
