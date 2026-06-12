class_name PopupViewport
extends Control
## The popup viewport (design.md "The Command Console", design_m3.md §6.4):
## a SubViewport with ITS OWN camera over the console — the main camera
## never moves, so closing the console restores exactly the prior view.
## Generic widget: owners react to view_dragged and the confirm/cancel
## signals. Strategy/Organize reuse it in M4+.
##
## Layout is positioned explicitly in _layout() (no anchor math under the
## CanvasLayer) and pointer input is handled by this control itself — the
## viewport container ignores the mouse, so nothing can swallow or
## reposition the hit area.

signal confirmed
signal cancelled
## Ground-plane point under the pointer (world coords), pressed or dragged.
signal view_dragged(world_point: Vector3)

const PITCH_DEG := 55.0
const DISTANCE := 22.0
const BAR_H := 56.0

var camera: Camera3D

var _panel: Panel
var _container: SubViewportContainer
var _viewport: SubViewport
var _bar: HBoxContainer
var _info: Label
var _confirm: Button
var _dragging := false


func _ready() -> void:
	visible = false
	mouse_filter = Control.MOUSE_FILTER_STOP

	_panel = Panel.new()
	_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_panel)

	_container = SubViewportContainer.new()
	_container.stretch = true
	_container.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_panel.add_child(_container)
	_viewport = SubViewport.new()
	_viewport.handle_input_locally = false
	_container.add_child(_viewport)
	# own_world_3d stays false: the popup renders the SAME world through a
	# separate camera.
	camera = Camera3D.new()
	camera.current = true
	_viewport.add_child(camera)

	_bar = HBoxContainer.new()
	_bar.add_theme_constant_override("separation", 10)
	_panel.add_child(_bar)
	_info = Label.new()
	_info.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_info.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_bar.add_child(_info)
	var cancel := Button.new()
	cancel.text = "Cancel"
	cancel.custom_minimum_size = Vector2(110, BAR_H - 12.0)
	cancel.pressed.connect(func() -> void:
		close()
		cancelled.emit())
	_bar.add_child(cancel)
	_confirm = Button.new()
	_confirm.text = "Confirm"
	_confirm.custom_minimum_size = Vector2(110, BAR_H - 12.0)
	_confirm.pressed.connect(func() -> void:
		close()
		confirmed.emit())
	_bar.add_child(_confirm)

	get_viewport().size_changed.connect(_layout)
	_layout()


## Everything positioned in screen pixels, recomputed on resize: the dim
## covers the whole screen, the panel floats centered (biased up so the
## half-detent console stays visible behind it).
func _layout() -> void:
	var vs := get_viewport().get_visible_rect().size
	position = Vector2.ZERO
	size = vs
	var panel_size := Vector2(minf(vs.x * 0.62, 860.0), minf(vs.y * 0.66, 560.0))
	_panel.position = Vector2((vs.x - panel_size.x) / 2.0, vs.y * 0.06)
	_panel.size = panel_size
	var pad := 8.0
	_container.position = Vector2(pad, pad)
	_container.size = Vector2(panel_size.x - 2.0 * pad,
			panel_size.y - BAR_H - 3.0 * pad)
	_bar.position = Vector2(pad, panel_size.y - BAR_H - pad)
	_bar.size = Vector2(panel_size.x - 2.0 * pad, BAR_H)


## Open over `center` (world coords); the popup camera frames it at the
## same fixed pitch the main rig uses.
func open(center: Vector3) -> void:
	jump_to(center)
	visible = true


func jump_to(center: Vector3) -> void:
	var pitch := deg_to_rad(PITCH_DEG)
	camera.position = center + Vector3(0.0, sin(pitch) * DISTANCE, cos(pitch) * DISTANCE)
	camera.look_at(center)


func close() -> void:
	visible = false
	_dragging = false


func set_info(text: String) -> void:
	_info.text = text


func set_confirm_enabled(enabled: bool) -> void:
	_confirm.disabled = not enabled


## Pointer handling for the whole popup: presses/drags inside the
## viewport area report ground points; everywhere else just blocks.
func _gui_input(event: InputEvent) -> void:
	var pos := Vector2.ZERO
	var report := false
	if event is InputEventScreenTouch:
		_dragging = event.pressed and _in_view(event.position)
		report = _dragging
		pos = event.position
	elif event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		_dragging = event.pressed and _in_view(event.position)
		report = _dragging
		pos = event.position
	elif (event is InputEventScreenDrag or event is InputEventMouseMotion) \
			and _dragging:
		report = _in_view(event.position)
		pos = event.position
	accept_event()
	if not report:
		return
	var local := pos - _container.position - _panel.position
	var hit: Variant = Plane(Vector3.UP, 0.0).intersects_ray(
			camera.project_ray_origin(local), camera.project_ray_normal(local))
	if hit != null:
		view_dragged.emit(hit)


func _in_view(point: Vector2) -> bool:
	return Rect2(_panel.position + _container.position, _container.size) \
			.has_point(point)


func _draw() -> void:
	# Dim everything underneath; the popup is modal.
	draw_rect(Rect2(Vector2.ZERO, size), Color(0.0, 0.0, 0.0, 0.45))
