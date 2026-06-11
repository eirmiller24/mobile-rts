class_name TouchButton
extends Control
## Base for HUD buttons that need press tracking beyond the control's rect
## (hold-and-swipe radials, long-press). Grabs the pointer on press in
## _gui_input, then follows drag/release globally in _input, because GUI
## event delivery stops at the rect edge but a swipe doesn't.
##
## Handles both raw touches and mouse, guarding against the duplicate
## events produced by touch<->mouse emulation: whichever modality presses
## first wins, later presses are ignored until release.

## Grabbed pointer: >= 0 is a touch index, MOUSE_GRAB is the mouse, -1 idle.
const MOUSE_GRAB := -2

var held_time := 0.0
## Pointer position in viewport coordinates while grabbed.
var pointer_pos := Vector2.ZERO

var _grab := -1


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	set_process(false)


func is_pressed_now() -> bool:
	return _grab != -1


func center() -> Vector2:
	return get_global_rect().get_center()


func _gui_input(event: InputEvent) -> void:
	if _grab == -1:
		if event is InputEventScreenTouch and event.pressed:
			_start_grab(event.index, event.position + get_global_rect().position)
		elif event is InputEventMouseButton and event.pressed \
				and event.button_index == MOUSE_BUTTON_LEFT:
			_start_grab(MOUSE_GRAB, event.position + get_global_rect().position)
	accept_event()


func _input(event: InputEvent) -> void:
	if _grab == -1:
		return
	if _grab >= 0:
		if event is InputEventScreenDrag and event.index == _grab:
			pointer_pos = event.position
			_pointer_moved()
		elif event is InputEventScreenTouch and not event.pressed \
				and event.index == _grab:
			_end_grab()
	else:
		if event is InputEventMouseMotion:
			pointer_pos = event.position
			_pointer_moved()
		elif event is InputEventMouseButton and not event.pressed \
				and event.button_index == MOUSE_BUTTON_LEFT:
			_end_grab()


func _process(delta: float) -> void:
	held_time += delta
	_held(held_time)


func _start_grab(grab_id: int, pos: Vector2) -> void:
	_grab = grab_id
	held_time = 0.0
	pointer_pos = pos
	set_process(true)
	_press_started()
	queue_redraw()


func _end_grab() -> void:
	var t := held_time
	_grab = -1
	set_process(false)
	_released(t)
	queue_redraw()


# Subclass hooks.
func _press_started() -> void:
	pass


func _pointer_moved() -> void:
	pass


func _held(_time: float) -> void:
	pass


func _released(_held_for: float) -> void:
	pass
