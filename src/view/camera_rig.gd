class_name CameraRig
extends Node3D
## Commander camera: fixed pitch, two-finger pan/pinch(/twist) on touch,
## with mouse fallbacks for desktop iteration (wheel zoom, MMB pan, RMB
## rotate). The rig node sits on the ground plane; the Camera3D child is
## positioned by pitch + zoom distance.
##
## View-layer code: floats are fine here.

@export var pitch_deg := 55.0
@export var min_zoom := 8.0
@export var max_zoom := 60.0
@export var zoom_step := 1.1
@export var rotation_enabled := true # tentative, see design.md open questions

var _zoom := 30.0
var _yaw := 0.0
## touch index -> screen position of active touches
var _touches: Dictionary = {}

@onready var _camera: Camera3D = $Camera3D


func _ready() -> void:
	_update_camera()


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventScreenTouch:
		if event.pressed:
			_touches[event.index] = event.position
		else:
			_touches.erase(event.index)
	elif event is InputEventScreenDrag:
		_handle_drag(event)
	elif event is InputEventMouseButton:
		_handle_mouse_button(event)
	elif event is InputEventMouseMotion:
		_handle_mouse_motion(event)


## Single-finger drags belong to the selection layer; the camera only
## responds when exactly two fingers are down.
func _handle_drag(event: InputEventScreenDrag) -> void:
	if not _touches.has(event.index):
		return
	if _touches.size() != 2:
		_touches[event.index] = event.position
		return

	var other_index: int = _touches.keys().filter(
		func(i: int) -> bool: return i != event.index)[0]
	var anchor: Vector2 = _touches[other_index]
	var before: Vector2 = _touches[event.index]
	var after := event.position
	_touches[event.index] = after

	# Pan from centroid movement.
	_pan_screen((after - before) * 0.5)

	# Zoom from pinch distance ratio.
	var dist_before := anchor.distance_to(before)
	var dist_after := anchor.distance_to(after)
	if dist_before > 1.0 and dist_after > 1.0:
		_set_zoom(_zoom * dist_before / dist_after)

	# Rotate from twist angle.
	if rotation_enabled:
		var angle_delta := (before - anchor).angle_to(after - anchor)
		_yaw -= angle_delta
	_update_camera()


func _handle_mouse_button(event: InputEventMouseButton) -> void:
	if event.button_index == MOUSE_BUTTON_WHEEL_UP:
		_set_zoom(_zoom / zoom_step)
		_update_camera()
	elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
		_set_zoom(_zoom * zoom_step)
		_update_camera()


func _handle_mouse_motion(event: InputEventMouseMotion) -> void:
	if event.button_mask & MOUSE_BUTTON_MASK_MIDDLE:
		_pan_screen(event.relative)
		_update_camera()
	elif rotation_enabled and event.button_mask & MOUSE_BUTTON_MASK_RIGHT:
		_yaw -= event.relative.x * 0.005
		_update_camera()


## Convert a screen-space drag into ground-plane motion (opposite the drag,
## as if grabbing the map), scaled so the world point stays under the finger.
func _pan_screen(screen_delta: Vector2) -> void:
	var viewport_height := float(get_viewport().get_visible_rect().size.y)
	var world_per_pixel := 2.0 * _zoom * tan(
		deg_to_rad(_camera.fov * 0.5)) / viewport_height
	var motion := -screen_delta * world_per_pixel
	position += Vector3(motion.x, 0.0, motion.y).rotated(Vector3.UP, _yaw)


func _set_zoom(value: float) -> void:
	_zoom = clampf(value, min_zoom, max_zoom)


func reset_rotation() -> void:
	_yaw = 0.0
	_update_camera()


func _update_camera() -> void:
	rotation.y = _yaw
	var pitch := deg_to_rad(pitch_deg)
	_camera.position = Vector3(0.0, _zoom * sin(pitch), _zoom * cos(pitch))
	_camera.look_at(global_position, Vector3.UP)
