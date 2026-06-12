class_name ViewportPlacement
extends Control
## Direct placement in the main viewport (design.md "The Command
## Console": "swipe the menu down to return to the main viewport and
## place their building that way"). Picking a structure in the Build tab
## arms this mode: taps on the ground position the shared PlacementGhost,
## and a floating bar above the console handle shows cost/validity with
## Confirm/Cancel. Placement commits on Confirm, never on tap.

signal place_confirmed(type_key: int, cx: int, cy: int)

const BAR_H := 52.0

var sim: Sim
var local_player := 1
var world_offset := 32.0
var ghost_parent: Node3D

var _ghost: PlacementGhost
var _info: Label
var _confirm: Button


func _ready() -> void:
	visible = false
	mouse_filter = Control.MOUSE_FILTER_STOP
	var bar := HBoxContainer.new()
	bar.set_anchors_preset(Control.PRESET_FULL_RECT)
	bar.add_theme_constant_override("separation", 10)
	add_child(bar)
	_info = Label.new()
	_info.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bar.add_child(_info)
	var cancel := Button.new()
	cancel.text = "Cancel"
	cancel.custom_minimum_size = Vector2(100, BAR_H - 8.0)
	cancel.pressed.connect(cancel_placement)
	bar.add_child(cancel)
	_confirm = Button.new()
	_confirm.text = "Confirm"
	_confirm.custom_minimum_size = Vector2(100, BAR_H - 8.0)
	_confirm.pressed.connect(_on_confirm)
	bar.add_child(_confirm)
	_layout()
	get_viewport().size_changed.connect(_layout)


func _layout() -> void:
	var vs := get_viewport().get_visible_rect().size
	var width := minf(640.0, vs.x * 0.6)
	position = Vector2((vs.x - width) / 2.0, vs.y - ConsoleView.HANDLE_H - BAR_H - 10.0)
	size = Vector2(width, BAR_H)


func is_active() -> bool:
	return visible


func begin(type_key: int) -> void:
	cancel_placement()
	_ghost = PlacementGhost.new()
	_ghost.sim = sim
	_ghost.local_player = local_player
	_ghost.world_offset = world_offset
	_ghost.visible = false # appears on the first tap
	ghost_parent.add_child(_ghost)
	_ghost.set_type(type_key)
	visible = true
	_info.text = "Tap the map to position: %s" % \
			sim.catalog.ui_of(type_key).get("label", sim.catalog.id_of(type_key))
	_confirm.disabled = true


## Viewport tap while armed: position the ghost there. Returns true when
## the tap was consumed (the selection controller checks this first).
func handle_tap(world_pos: Vector3) -> bool:
	if not is_active() or _ghost == null:
		return false
	_ghost.visible = true
	_ghost.move_to_world(world_pos)
	var verdict := _ghost.evaluate()
	_info.text = verdict["info"]
	_confirm.disabled = verdict["blocked"]
	return true


func cancel_placement() -> void:
	visible = false
	if _ghost != null:
		_ghost.queue_free()
		_ghost = null


func _on_confirm() -> void:
	if _ghost == null or not _ghost.visible:
		return
	var type: int = _ghost.type
	var cx: int = _ghost.cx
	var cy: int = _ghost.cy
	cancel_placement()
	place_confirmed.emit(type, cx, cy)


func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), Color(0.07, 0.08, 0.1, 0.92))
	draw_rect(Rect2(Vector2.ZERO, size), Color(1, 1, 1, 0.25), false, 1.0)
