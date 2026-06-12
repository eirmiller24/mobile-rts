class_name SelectionController
extends Node
## Interprets viewport gestures into selection and orders (design.md
## "Controls"): tap to select, lasso to multi-select, context-sensitive
## second tap to order, side-button verbs overriding context. Single
## finger only — two-finger gestures belong to the camera and cancel any
## gesture in progress here.
##
## Command grammar is subject-verb-object: select units, choose a verb
## (side button), then tap the object. Untargeted verbs (stop, hold)
## execute the moment they're chosen; a verb with no selection does
## nothing. Which command each context kind maps to comes from the UI
## catalog; this controller decides *that* an order happens, never what
## it means.

signal selection_changed(units: Array[UnitView])
signal order_issued(command_id: String, units: Array[UnitView],
		world_pos: Vector3, target: UnitView)
## Stationary single-finger hold on empty ground with nothing selected —
## the "designate this spot" gesture (design_m3.md §6.1).
signal long_pressed(world_pos: Vector3)

const TAP_MOVE_THRESHOLD := 16.0
const PICK_RADIUS_PX := 48.0
const LONG_PRESS_TIME := 0.6

var camera: Camera3D
var hud: Hud
var catalog: UICatalog
var auto_deselect := true
## When valid and returning true, an armed placement mode consumed the
## tap (func(world_pos: Vector3) -> bool) — checked before selection.
var placement_tap := Callable()

var selection: Array[UnitView] = []
var last_group: Array[UnitView] = []

## Chosen verb awaiting its object (targeted commands only).
var _armed := ""
var _active_index := -1
var _path := PackedVector2Array()
var _moved := false
var _cancelled := false
var _touch_count := 0
var _press_held := 0.0


func _process(delta: float) -> void:
	if _active_index == -1 or _moved or _cancelled:
		return
	_press_held += delta
	if _press_held >= LONG_PRESS_TIME and selection.is_empty():
		_cancelled = true # consume the gesture; release does nothing more
		long_pressed.emit(_ground_point(_path[0]))
		Input.vibrate_handheld(30)


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventScreenTouch:
		if event.pressed:
			_touch_count += 1
			if _touch_count == 1 and not hud.is_point_on_ui(event.position):
				_active_index = event.index
				_path = PackedVector2Array([event.position])
				_moved = false
				_cancelled = false
				_press_held = 0.0
			else:
				# Second finger = camera gesture; abandon selection gesture.
				_cancelled = true
				hud.lasso_overlay.set_points(PackedVector2Array())
		else:
			_touch_count = maxi(0, _touch_count - 1)
			if event.index == _active_index:
				if not _cancelled:
					_finish(event.position)
				_active_index = -1
				hud.lasso_overlay.set_points(PackedVector2Array())
	elif event is InputEventScreenDrag \
			and event.index == _active_index and not _cancelled:
		_path.append(event.position)
		if not _moved \
				and event.position.distance_to(_path[0]) > TAP_MOVE_THRESHOLD:
			_moved = true
		if _moved:
			hud.lasso_overlay.set_points(_path)


## A verb was chosen from the side buttons. Needs a subject; untargeted
## verbs execute immediately, targeted ones arm and await an object tap.
func choose_command(command_id: String) -> void:
	if selection.is_empty():
		hud.set_status("select units first")
		return
	var def := catalog.command(command_id)
	if def != null and not def.targeted:
		_issue(command_id, null, _selection_centroid())
	else:
		_armed = command_id
		hud.set_armed(command_id)


func reselect() -> void:
	var alive: Array[UnitView] = []
	for u in last_group:
		if is_instance_valid(u):
			alive.append(u)
	if not alive.is_empty():
		_select(alive)


func _finish(pos: Vector2) -> void:
	if _moved:
		_lasso()
	else:
		_tap(pos)


func _tap(pos: Vector2) -> void:
	if placement_tap.is_valid() and placement_tap.call(_ground_point(pos)):
		return # structure placement owns viewport taps while armed
	var unit := _pick_unit(pos)
	if selection.is_empty():
		if unit != null and unit.selectable:
			_select([unit])
		return

	var verb := hud.take_modifier()
	if verb.is_empty():
		verb = _armed
	var world := unit.global_position if unit != null else _ground_point(pos)
	if not verb.is_empty():
		_issue(verb, unit, world)
		return
	if unit == null:
		_issue(catalog.context_orders["ground"], null, world)
	elif unit.selectable:
		_select([unit]) # tapping an own unit always re-selects
	elif unit.faction == UnitView.FACTION_ENEMY:
		_issue(catalog.context_orders["enemy"], unit, world)
	else:
		# Neutral resources and own structures: the resource context order
		# (the Hive maps it to move — workers are a Rebel thing).
		_issue(catalog.context_orders["resource"], unit, world)


func _lasso() -> void:
	if _path.size() < 3:
		return
	var hits: Array[UnitView] = []
	for u in _all_units():
		if not u.selectable:
			continue
		if camera.is_position_behind(u.global_position):
			continue
		var sp := camera.unproject_position(u.global_position)
		if Geometry2D.is_point_in_polygon(sp, _path):
			hits.append(u)
	if not hits.is_empty():
		_select(hits)


func _issue(command_id: String, target: UnitView, world: Vector3) -> void:
	_armed = ""
	hud.set_armed("")
	last_group = selection.duplicate()
	order_issued.emit(command_id, selection.duplicate(), world, target)
	Input.vibrate_handheld(25)
	if auto_deselect:
		_select([])


func _select(units: Array[UnitView]) -> void:
	# Changing the subject mid-sentence drops the armed verb.
	_armed = ""
	hud.set_armed("")
	for u in selection:
		if is_instance_valid(u):
			u.selected = false
	selection = units
	for u in selection:
		u.selected = true
	if not selection.is_empty():
		last_group = selection.duplicate()
		Input.vibrate_handheld(15)
	selection_changed.emit(selection)


func _pick_unit(pos: Vector2) -> UnitView:
	var best: UnitView = null
	var best_dist := PICK_RADIUS_PX
	for u in _all_units():
		if camera.is_position_behind(u.global_position):
			continue
		var d := camera.unproject_position(u.global_position).distance_to(pos)
		if d < best_dist:
			best_dist = d
			best = u
	return best


func _selection_centroid() -> Vector3:
	var sum := Vector3.ZERO
	var count := 0
	for u in selection:
		if is_instance_valid(u):
			sum += u.global_position
			count += 1
	return sum / count if count > 0 else Vector3.ZERO


func _ground_point(pos: Vector2) -> Vector3:
	var hit: Variant = Plane(Vector3.UP, 0.0).intersects_ray(
			camera.project_ray_origin(pos), camera.project_ray_normal(pos))
	return hit if hit != null else Vector3.ZERO


func _all_units() -> Array[UnitView]:
	var result: Array[UnitView] = []
	for node in get_tree().get_nodes_in_group("units"):
		result.append(node as UnitView)
	return result
