class_name PlacementPopup
extends PopupViewport
## Structure placement over the popup viewport (design_m3.md §6.4): drag
## to move the shared PlacementGhost; placement commits on Confirm, not
## on tap — fingers are imprecise.

signal place_confirmed(type_key: int, cx: int, cy: int)

var sim: Sim
var local_player := 1
var world_offset := 32.0
## Node the ghost mesh attaches to (the 3D scene root).
var ghost_parent: Node3D

var _ghost: PlacementGhost


func _ready() -> void:
	super()
	view_dragged.connect(_on_view_dragged)
	confirmed.connect(_on_confirmed)
	cancelled.connect(_remove_ghost)


## Arm placement of a structure type around a starting point (sim fixed).
func begin(type_key: int, start_x: int, start_y: int) -> void:
	_remove_ghost()
	_ghost = PlacementGhost.new()
	_ghost.sim = sim
	_ghost.local_player = local_player
	_ghost.world_offset = world_offset
	ghost_parent.add_child(_ghost)
	_ghost.set_type(type_key)
	_ghost.move_to_world(Vector3(Fixed.to_float(start_x) - world_offset, 0.0,
			Fixed.to_float(start_y) - world_offset))
	open(_ghost.footprint_center())
	_refresh()


func _on_view_dragged(world_point: Vector3) -> void:
	if _ghost == null:
		return
	_ghost.move_to_world(world_point)
	_refresh()


func _refresh() -> void:
	var verdict := _ghost.evaluate()
	set_info(verdict["info"])
	set_confirm_enabled(not verdict["blocked"])


func _on_confirmed() -> void:
	if _ghost == null:
		return
	var type: int = _ghost.type
	var cx: int = _ghost.cx
	var cy: int = _ghost.cy
	_remove_ghost()
	place_confirmed.emit(type, cx, cy)


func _remove_ghost() -> void:
	if _ghost != null:
		_ghost.queue_free()
		_ghost = null
