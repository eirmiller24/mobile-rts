class_name DesignationButton
extends TouchButton
## The third side button (design.md "The designation button"), built on
## the same hold-and-swipe idiom as RadialButton:
##  - tap with units selected: assign the selection to the next free slot
##  - hold with units selected: petals are slots 1-4, swipe to pick one
##  - tap/hold with nothing selected: petals are the first designations,
##    swipe to recall one (select the group / jump to the location)
## What a slot *contains* lives in the Designations store; this control
## only reports intents.

signal assign_requested(slot: int) # -1 = next free
signal recall_requested(slot: int)

const HOLD_TIME := 0.25
const RADIUS := 44.0
const DEAD_ZONE := 48.0
const PETAL_OFFSET := 104.0
const PETAL_RADIUS := 34.0
const DIRS := [Vector2.UP, Vector2.RIGHT, Vector2.DOWN, Vector2.LEFT]

var designations: Designations
## Supplied by the HUD: returns true when units are currently selected.
var has_selection := Callable()

var _radial_open := false


func setup(p_designations: Designations) -> void:
	designations = p_designations
	custom_minimum_size = Vector2.ONE * (RADIUS * 2.0 + 12.0)


func _press_started() -> void:
	_radial_open = false


func _pointer_moved() -> void:
	if _radial_open:
		queue_redraw()


func _held(time: float) -> void:
	if not _radial_open and time >= HOLD_TIME:
		_radial_open = true
		queue_redraw()


func _released(_held_for: float) -> void:
	var assigning: bool = has_selection.is_valid() and has_selection.call()
	var petal := _petal_under_pointer() if _radial_open else -1
	_radial_open = false
	queue_redraw()
	if assigning:
		if petal == -1:
			assign_requested.emit(-1)
		else:
			assign_requested.emit(petal)
	else:
		var slot := _recall_slot(petal)
		if slot != -1:
			recall_requested.emit(slot)


## Petal index 0..3 under the pointer, or -1 inside the dead zone.
func _petal_under_pointer() -> int:
	var v := pointer_pos - center()
	if v.length() < DEAD_ZONE:
		return -1
	if absf(v.x) > absf(v.y):
		return 1 if v.x > 0.0 else 3
	return 2 if v.y > 0.0 else 0


## Recall petals map to the first four occupied slots; a bare tap recalls
## the most recent designation.
func _recall_slot(petal: int) -> int:
	var occ := designations.occupied()
	if occ.is_empty():
		return -1
	if petal == -1:
		return occ[occ.size() - 1]["slot"]
	if petal < occ.size():
		return occ[petal]["slot"]
	return -1


func _draw() -> void:
	var c := size * 0.5
	var base_color := Color(0.15, 0.17, 0.2, 0.85)
	if is_pressed_now():
		base_color = Color(0.25, 0.28, 0.33, 0.9)
	draw_circle(c, RADIUS, base_color)
	draw_arc(c, RADIUS, 0.0, TAU, 48, Color(1, 1, 1, 0.5), 2.0)
	_label(c, "Desig", Color.WHITE)

	if not _radial_open:
		return
	var assigning: bool = has_selection.is_valid() and has_selection.call()
	var live := _petal_under_pointer()
	for i in 4:
		var pc: Vector2 = c + DIRS[i] * PETAL_OFFSET
		var text := ""
		var fill := Color(0.12, 0.14, 0.18, 0.9)
		if assigning:
			var e: Variant = designations.entry(i)
			text = "%d:%s" % [i + 1, e["name"]] if e != null else str(i + 1)
		else:
			var occ := designations.occupied()
			if i < occ.size():
				text = occ[i]["entry"]["name"]
			else:
				fill.a = 0.35
		if i == live:
			fill = Color(0.3, 0.5, 0.4, 0.95)
		draw_circle(pc, PETAL_RADIUS, fill)
		draw_arc(pc, PETAL_RADIUS, 0.0, TAU, 40, Color(1, 1, 1, 0.6), 2.0)
		if not text.is_empty():
			_label(pc, text, Color.WHITE)


func _label(at: Vector2, text: String, color: Color) -> void:
	draw_string(ThemeDB.fallback_font, at + Vector2(-60.0, 5.0), text,
			HORIZONTAL_ALIGNMENT_CENTER, 120.0, 12, color)
