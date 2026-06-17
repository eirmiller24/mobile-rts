class_name ViewportPlacement
extends Control
## Direct in-viewport build planner (design.md "swipe the menu down and place
## that way"; design_m4.md §4.4 drawn walls). Picking a structure in the Build
## tab arms this: a press-drag-release on the ground drops a ghost into a
## *pending plan*, and a floating bar shows the running cost with Confirm /
## Cancel. Nothing reaches the sim until Confirm — then the whole plan goes out
## as one BUILD per building plus one BUILD_WALL for the drawn cells.
##
## Two gesture shapes, chosen by the held Control modifier and whether the
## armed structure is a wall (is_wall, the 1x1 Barricade):
##  - no Control: a single ghost follows the finger and drops on release,
##    *replacing* the plan — so you can retry a placement until it's exact.
##  - Control + normal building: same single drop but *appended* — tap a bunch
##    of spots to lay a WC3-style maze.
##  - Control + wall: the drag is rasterized into a contiguous run of wall
##    cells (WallStroke), its start snapped onto a nearby pending post — place
##    one post precisely, then hold Control and draw the wall out of it.
## The sim is still the judge at Confirm; blocked cells/footprints just no-op.

## Emitted on Confirm. structures: Array of {type, cx, cy}. wall_cells: the
## drawn pathing cells; wall_type: the wall structure (-1 if no wall drawn).
signal plan_committed(structures: Array, wall_cells: PackedInt32Array,
		wall_type: int)

const BAR_H := 52.0
## Control+wall stroke start snaps onto a pending post within this many world
## units (fingers don't have half-tile accuracy).
const SNAP_DIST := 1.6

var sim: Sim
var local_player := 1
var world_offset := 32.0
var ghost_parent: Node3D

var _armed_type := -1
var _is_wall := false

## Pending plan. Buildings each own a persistent ghost; the wall is a flat set
## of cells with its own thin preview boxes.
var _structures: Array[Dictionary] = []
var _plan_ghosts: Array[PlacementGhost] = []
var _wall_cells := PackedInt32Array()
var _wall_nodes: Array[MeshInstance3D] = []

## The ghost following the finger during a single-drop gesture.
var _active_ghost: PlacementGhost
## In-progress Control+wall stroke.
var _stroking := false
var _stroke_points: Array[Vector3] = []
var _stroke_start := -1
var _stroke_nodes: Array[MeshInstance3D] = []

var _info: Label
var _confirm: Button


func _ready() -> void:
	visible = false
	# STOP so the bar itself eats taps beneath it; the map gesture is routed to
	# us by the controller, which already treats this bar as a UI occluder.
	mouse_filter = Control.MOUSE_FILTER_STOP
	var bar := HBoxContainer.new()
	bar.set_anchors_preset(Control.PRESET_FULL_RECT)
	bar.add_theme_constant_override("separation", 10)
	add_child(bar)
	_info = Label.new()
	_info.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_info.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
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
	var width := minf(680.0, vs.x * 0.6)
	position = Vector2((vs.x - width) / 2.0, vs.y - ConsoleView.HANDLE_H - BAR_H - 10.0)
	size = Vector2(width, BAR_H)


func is_active() -> bool:
	return visible


## Arm a build. The mode (single building vs. drawn wall) is read from the
## structure's is_wall flag, so picking the Barricade from the grid draws walls
## with no separate verb.
func begin(type_key: int) -> void:
	cancel_placement()
	_armed_type = type_key
	_is_wall = sim.catalog.sim_of(type_key).get("is_wall", false)
	visible = true
	_refresh_bar()


# --- gesture entry points (called by SelectionController) ----------------------


func press(world: Vector3, control: bool) -> void:
	if _armed_type < 0:
		return
	if not control:
		_clear_plan()  # a fresh gesture replaces the pending plan
	if control and _is_wall:
		_begin_stroke(world)
	else:
		_begin_single(world)


func drag(world: Vector3) -> void:
	if _stroking:
		_stroke_points.append(world)
		_rebuild_stroke_preview()
	elif _active_ghost != null:
		_active_ghost.visible = true
		_active_ghost.move_to_world(world)
		_active_ghost.evaluate()


func release(world: Vector3) -> void:
	if _stroking:
		_finish_stroke()
	elif _active_ghost != null:
		_active_ghost.move_to_world(world)
		_commit_active_ghost()
	_refresh_bar()


# --- single-drop gesture (buildings, and a lone wall post) ---------------------


func _begin_single(world: Vector3) -> void:
	if _active_ghost == null:
		_active_ghost = _new_ghost(_armed_type)
		ghost_parent.add_child(_active_ghost)
	_active_ghost.visible = true
	_active_ghost.move_to_world(world)
	_active_ghost.evaluate()


func _commit_active_ghost() -> void:
	var cx: int = _active_ghost.cx
	var cy: int = _active_ghost.cy
	if _is_wall:
		_add_wall_cell(cy * sim.grid.width + cx)
		_active_ghost.queue_free()
		_active_ghost = null
	else:
		_structures.append({"type": _armed_type, "cx": cx, "cy": cy})
		_plan_ghosts.append(_active_ghost)  # keep it as the persistent preview
		_active_ghost = null


# --- Control+wall stroke -------------------------------------------------------


func _begin_stroke(world: Vector3) -> void:
	_stroking = true
	_stroke_points = [world]
	_stroke_start = WallStroke.snap_cell(sim.grid, _wall_cells,
			world.x, world.z, world_offset, SNAP_DIST)


func _finish_stroke() -> void:
	var cells := WallStroke.rasterize(sim.grid, _stroke_points, world_offset,
			_stroke_start)
	for c: int in cells:
		_add_wall_cell(c)
	_stroking = false
	_stroke_points = []
	_stroke_start = -1
	_clear_nodes(_stroke_nodes)


func _add_wall_cell(cell: int) -> void:
	if cell in _wall_cells:
		return
	_wall_cells.append(cell)
	_wall_nodes.append(_new_cell_box(cell, Color(0.55, 0.42, 0.24, 0.6)))


func _rebuild_stroke_preview() -> void:
	_clear_nodes(_stroke_nodes)
	var cells := WallStroke.rasterize(sim.grid, _stroke_points, world_offset,
			_stroke_start)
	for c: int in cells:
		if c not in _wall_cells:
			_stroke_nodes.append(_new_cell_box(c, Color(0.3, 0.85, 0.45, 0.55)))


# --- commit / cancel -----------------------------------------------------------


func _on_confirm() -> void:
	if _structures.is_empty() and _wall_cells.is_empty():
		return
	var structures := _structures.duplicate(true)
	var cells := _wall_cells.duplicate()
	var wall_type := _armed_type if _is_wall and not cells.is_empty() else -1
	cancel_placement()
	plan_committed.emit(structures, cells, wall_type)


## Drop the in-progress gesture (a second finger grabbed the camera mid-draw)
## but keep the committed plan — the player can resume drawing.
func abort_gesture() -> void:
	_stroking = false
	_stroke_points = []
	_stroke_start = -1
	_clear_nodes(_stroke_nodes)
	if _active_ghost != null:
		_active_ghost.queue_free()
		_active_ghost = null
	_refresh_bar()


func cancel_placement() -> void:
	visible = false
	_armed_type = -1
	_clear_plan()


func _clear_plan() -> void:
	_structures.clear()
	_wall_cells = PackedInt32Array()
	_stroking = false
	_stroke_points = []
	_stroke_start = -1
	if _active_ghost != null:
		_active_ghost.queue_free()
		_active_ghost = null
	for g in _plan_ghosts:
		if is_instance_valid(g):
			g.queue_free()
	_plan_ghosts.clear()
	_clear_nodes(_wall_nodes)
	_clear_nodes(_stroke_nodes)
	_refresh_bar()


# --- helpers -------------------------------------------------------------------


func _new_ghost(type_key: int) -> PlacementGhost:
	var g := PlacementGhost.new()
	g.sim = sim
	g.local_player = local_player
	g.world_offset = world_offset
	g.visible = false
	g.set_type(type_key)
	return g


## A thin translucent box marking one pathing cell (wall preview).
func _new_cell_box(cell: int, color: Color) -> MeshInstance3D:
	var cx := cell % sim.grid.width
	var cy := cell / sim.grid.width
	var node := MeshInstance3D.new()
	var box := BoxMesh.new()
	var side := 1.0 / SimGrid.PATH_SUBDIV
	box.size = Vector3(side * 0.92, 1.0, side * 0.92)
	var mat := StandardMaterial3D.new()
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_color = color
	box.material = mat
	node.mesh = box
	node.position = Vector3(
			(cx + 0.5) / SimGrid.PATH_SUBDIV - world_offset, 0.5,
			(cy + 0.5) / SimGrid.PATH_SUBDIV - world_offset)
	ghost_parent.add_child(node)
	return node


func _clear_nodes(nodes: Array[MeshInstance3D]) -> void:
	for n in nodes:
		if is_instance_valid(n):
			n.queue_free()
	nodes.clear()


func _refresh_bar() -> void:
	var label: String = sim.catalog.ui_of(_armed_type).get("label",
			sim.catalog.id_of(_armed_type)) if _armed_type >= 0 else ""
	var parts: Array[String] = []
	if not _wall_cells.is_empty():
		var cost: int = _wall_cells.size() * sim.catalog.globals["wall_cost_alloy"]
		parts.append("%d wall (%d alloy)" % [_wall_cells.size(), cost])
	if not _structures.is_empty():
		var alloy := 0
		for s in _structures:
			alloy += sim.catalog.sim_of(s["type"])["cost_alloy"]
		parts.append("%d × %s (%d alloy)" % [_structures.size(), label, alloy])
	if parts.is_empty():
		var verb := "Draw" if _is_wall else "Place"
		_info.text = "%s %s — drag to lay it out, hold Ctrl to add more" % [verb, label]
		_confirm.disabled = true
	else:
		_info.text = "  +  ".join(parts)
		_confirm.disabled = false


func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), Color(0.07, 0.08, 0.1, 0.92))
	draw_rect(Rect2(Vector2.ZERO, size), Color(1, 1, 1, 0.25), false, 1.0)
