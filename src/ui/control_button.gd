class_name ControlButton
extends TouchButton
## The held "control" modifier on the right side (design.md "The control
## button"), the touch-native equivalent of a Ctrl key. While it is held
## (`is_pressed_now()`), other gestures change meaning: orders queue,
## unit/lasso selection adds/removes instead of replacing, a control-group
## chip is overwritten by the current selection, and a double-tap toggles a
## whole unit type. The controller and game root query the held state; this
## control owns none of that behavior.
##
## It is also a one-petal radial: hold to reveal a bottom petal, swipe to it
## and release to deselect everything. A plain tap (no hold, no swipe) does
## nothing — deselect-all must be deliberate, and a bare press is just the
## start of a modifier session.

signal deselect_all_requested
## Swipe to the top petal: snapshot the current selection into a fresh group.
signal new_group_requested

const HOLD_TIME := 0.25
const RADIUS := 44.0
const DEAD_ZONE := 48.0
const PETAL_OFFSET := 104.0
const PETAL_RADIUS := 34.0

var _radial_open := false


func setup() -> void:
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
	var petal := _petal_under_pointer() if _radial_open else ""
	_radial_open = false
	queue_redraw()
	match petal:
		"down":
			deselect_all_requested.emit()
		"up":
			new_group_requested.emit()


## Vertical petal under the pointer: "down" (deselect all) / "up" (new group),
## or "" inside the dead zone or off the vertical axis. Only the vertical axis
## carries petals, so a stray sideways drag releases harmlessly.
func _petal_under_pointer() -> String:
	var v := pointer_pos - center()
	if v.length() < DEAD_ZONE or absf(v.y) <= absf(v.x):
		return ""
	return "down" if v.y > 0.0 else "up"


func _draw() -> void:
	var c := size * 0.5
	var base_color := Color(0.15, 0.17, 0.2, 0.85)
	if is_pressed_now():
		base_color = Color(0.25, 0.28, 0.33, 0.9)
	draw_circle(c, RADIUS, base_color)
	draw_arc(c, RADIUS, 0.0, TAU, 48, Color(1, 1, 1, 0.5), 2.0)
	_label(c, "Ctrl", Color.WHITE)

	if not _radial_open:
		return
	var live := _petal_under_pointer()
	_petal(c + Vector2.UP * PETAL_OFFSET, "New group",
			Color(0.2, 0.4, 0.3, 0.9), Color(0.3, 0.7, 0.45, 0.97), live == "up")
	_petal(c + Vector2.DOWN * PETAL_OFFSET, "Deselect",
			Color(0.45, 0.2, 0.22, 0.9), Color(0.75, 0.3, 0.32, 0.97), live == "down")


func _petal(at: Vector2, text: String, idle: Color, active: Color, live: bool) -> void:
	draw_circle(at, PETAL_RADIUS, active if live else idle)
	draw_arc(at, PETAL_RADIUS, 0.0, TAU, 40, Color(1, 1, 1, 0.6), 2.0)
	_label(at, text, Color.WHITE)


func _label(at: Vector2, text: String, color: Color) -> void:
	draw_string(ThemeDB.fallback_font, at + Vector2(-60.0, 5.0), text,
			HORIZONTAL_ALIGNMENT_CENTER, 120.0, 12, color)
