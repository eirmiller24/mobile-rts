class_name PopupViewport
extends Control
## The popup viewport (design.md "The Command Console", design_m3.md §6.4):
## a SubViewport with ITS OWN camera over the console — the main camera
## never moves, so closing the console restores exactly the prior view.
## Generic widget: subclasses/owners supply content behavior via the
## view_dragged/view_tapped hooks and the confirm/cancel signals.
## Strategy/Organize reuse it in M4+.

signal confirmed
signal cancelled
## Ground-plane point under the pointer (world coords), pressed or dragged.
signal view_dragged(world_point: Vector3)

const PITCH_DEG := 55.0
const DISTANCE := 22.0
const BAR_H := 64.0

var camera: Camera3D

var _panel: PanelContainer
var _viewport: SubViewport
var _info: Label
var _confirm: Button
var _dragging := false


func _ready() -> void:
	visible = false
	mouse_filter = Control.MOUSE_FILTER_STOP
	set_anchors_preset(Control.PRESET_FULL_RECT)

	_panel = PanelContainer.new()
	_panel.anchor_left = 0.5
	_panel.anchor_right = 0.5
	_panel.anchor_top = 0.5
	_panel.anchor_bottom = 0.5
	add_child(_panel)

	var column := VBoxContainer.new()
	_panel.add_child(column)

	var container := SubViewportContainer.new()
	container.stretch = true
	column.add_child(container)
	_viewport = SubViewport.new()
	_viewport.handle_input_locally = false
	container.add_child(_viewport)
	# own_world_3d stays false: the popup renders the SAME world through a
	# separate camera.
	camera = Camera3D.new()
	_viewport.add_child(camera)

	var overlay := DragCatcher.new()
	overlay.popup = self
	overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	container.add_child(overlay)

	var bar := HBoxContainer.new()
	bar.custom_minimum_size.y = BAR_H - 16.0
	bar.add_theme_constant_override("separation", 10)
	column.add_child(bar)
	_info = Label.new()
	_info.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_info.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	bar.add_child(_info)
	var cancel := Button.new()
	cancel.text = "Cancel"
	cancel.custom_minimum_size = Vector2(110, BAR_H - 20.0)
	cancel.pressed.connect(func() -> void:
		close()
		cancelled.emit())
	bar.add_child(cancel)
	_confirm = Button.new()
	_confirm.text = "Confirm"
	_confirm.custom_minimum_size = Vector2(110, BAR_H - 20.0)
	_confirm.pressed.connect(func() -> void:
		close()
		confirmed.emit())
	bar.add_child(_confirm)

	get_viewport().size_changed.connect(_layout)
	_layout()


func _layout() -> void:
	var vs := get_viewport().get_visible_rect().size
	var panel_size := Vector2(minf(vs.x * 0.7, 900.0), minf(vs.y * 0.8, 620.0))
	_panel.offset_left = -panel_size.x / 2.0
	_panel.offset_right = panel_size.x / 2.0
	_panel.offset_top = -panel_size.y / 2.0
	_panel.offset_bottom = panel_size.y / 2.0


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


func set_info(text: String) -> void:
	_info.text = text


func set_confirm_enabled(enabled: bool) -> void:
	_confirm.disabled = not enabled


func _project_to_ground(local_pos: Vector2) -> Variant:
	return Plane(Vector3.UP, 0.0).intersects_ray(
			camera.project_ray_origin(local_pos),
			camera.project_ray_normal(local_pos))


func _draw() -> void:
	# Dim everything underneath; the popup is modal.
	draw_rect(Rect2(Vector2.ZERO, size), Color(0.0, 0.0, 0.0, 0.45))


class DragCatcher:
	extends Control
	## Captures press/drag over the viewport and reports ground-plane
	## points. SubViewportContainer would forward events into the (empty)
	## SubViewport; placement wants them here.

	var popup: PopupViewport

	func _ready() -> void:
		mouse_filter = Control.MOUSE_FILTER_STOP

	func _gui_input(event: InputEvent) -> void:
		var report := false
		var pos := Vector2.ZERO
		if event is InputEventScreenTouch:
			popup._dragging = event.pressed
			report = event.pressed
			pos = event.position
		elif event is InputEventMouseButton \
				and event.button_index == MOUSE_BUTTON_LEFT:
			popup._dragging = event.pressed
			report = event.pressed
			pos = event.position
		elif (event is InputEventScreenDrag or event is InputEventMouseMotion) \
				and popup._dragging:
			report = true
			pos = event.position
		if not report:
			return
		accept_event()
		var hit: Variant = popup._project_to_ground(pos)
		if hit != null:
			popup.view_dragged.emit(hit)
