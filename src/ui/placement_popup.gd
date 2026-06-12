class_name PlacementPopup
extends PopupViewport
## Structure placement over the popup viewport (design_m3.md §6.4): ghost
## footprint mesh snapped to pathing cells, green/red validity tint from a
## client-side prediction of the sim's vision-gated checks — amber when
## the footprint overlaps fog (placeable, at your own risk). Drag to move;
## placement commits on Confirm, not on tap — fingers are imprecise.

signal place_confirmed(type_key: int, cx: int, cy: int)

var sim: Sim
var local_player := 1
var world_offset := 32.0
## Node the ghost mesh attaches to (the 3D scene root).
var ghost_parent: Node3D

var _type := -1
var _cx := 0
var _cy := 0
var _ghost: MeshInstance3D
var _ghost_mat: StandardMaterial3D


func _ready() -> void:
	super()
	view_dragged.connect(_on_view_dragged)
	confirmed.connect(_on_confirmed)
	cancelled.connect(_remove_ghost)


## Arm placement of a structure type around a starting point (sim fixed).
func begin(type_key: int, start_x: int, start_y: int) -> void:
	_type = type_key
	var s := sim.catalog.sim_of(type_key)
	_remove_ghost()
	_ghost = MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3(s["foot_w"] * 0.5, 0.8, s["foot_h"] * 0.5)
	_ghost_mat = StandardMaterial3D.new()
	_ghost_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	box.material = _ghost_mat
	_ghost.mesh = box
	ghost_parent.add_child(_ghost)
	_set_cells_from_world(_sim_to_world(start_x, start_y))
	open(_footprint_center_world())
	_refresh()


func _on_view_dragged(world_point: Vector3) -> void:
	if _ghost == null:
		return
	_set_cells_from_world(world_point)
	_refresh()


func _on_confirmed() -> void:
	_remove_ghost()
	place_confirmed.emit(_type, _cx, _cy)


func _set_cells_from_world(p: Vector3) -> void:
	var s := sim.catalog.sim_of(_type)
	var w: int = s["foot_w"]
	var h: int = s["foot_h"]
	_cx = clampi(int(floor((p.x + world_offset) * SimGrid.PATH_SUBDIV)) - w / 2,
			0, sim.grid.width - w)
	_cy = clampi(int(floor((p.z + world_offset) * SimGrid.PATH_SUBDIV)) - h / 2,
			0, sim.grid.height - h)


## Client-side prediction of BUILD validation (§4.5) — the sim is still
## the judge at execution; a stale prediction just no-ops.
func _refresh() -> void:
	var s := sim.catalog.sim_of(_type)
	var w: int = s["foot_w"]
	var h: int = s["foot_h"]
	var blocked := false
	var fogged := false
	if s["builds_on_vent"]:
		var vent := sim.vent_at(_cx, _cy, w, h)
		blocked = vent == 0 or sim.vent_taken(vent)
	else:
		for fy in range(_cy, _cy + h):
			for fx in range(_cx, _cx + w):
				var vis := sim.is_cell_visible(local_player, fx, fy)
				if not vis:
					fogged = true
				elif sim.grid.is_blocked(fx, fy):
					blocked = true
	var center := _footprint_center_world()
	var inside := sim.territory_covers(local_player,
			Fixed.from_float(center.x + world_offset),
			Fixed.from_float(center.z + world_offset))
	var cost: int = s["cost_alloy"] + (0 if inside else s["capsule_cost_alloy"])

	_ghost.position = center + Vector3(0, 0.4, 0)
	var color := Color(0.3, 0.9, 0.4, 0.45)
	var info := "%s — %d alloy" % [
			sim.catalog.ui_of(_type).get("label", sim.catalog.id_of(_type)), cost]
	if s["cost_flux"] > 0:
		info += " + %d flux" % s["cost_flux"]
	if not inside:
		info += "  (outside influence: capsule +%d)" % s["capsule_cost_alloy"]
	if blocked:
		color = Color(0.9, 0.25, 0.2, 0.5)
		info += "  BLOCKED"
	elif fogged:
		color = Color(0.95, 0.75, 0.25, 0.5)
		info += "  unseen ground — capsule at risk"
	_ghost_mat.albedo_color = color
	set_info(info)
	set_confirm_enabled(not blocked)


func _footprint_center_world() -> Vector3:
	var s := sim.catalog.sim_of(_type)
	return Vector3(
			(_cx + s["foot_w"] / 2.0) / SimGrid.PATH_SUBDIV - world_offset, 0.0,
			(_cy + s["foot_h"] / 2.0) / SimGrid.PATH_SUBDIV - world_offset)


func _sim_to_world(x: int, y: int) -> Vector3:
	return Vector3(Fixed.to_float(x) - world_offset, 0.0,
			Fixed.to_float(y) - world_offset)


func _remove_ghost() -> void:
	if _ghost != null:
		_ghost.queue_free()
		_ghost = null
