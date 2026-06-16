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
## Double-tap a unit to grab every unit of its type within this screen
## radius of the second tap.
const DOUBLE_TAP_MS := 350
const DOUBLE_TAP_DIST := 48.0
const SAME_TYPE_RADIUS_PX := 220.0

var camera: Camera3D
var hud: Hud
var catalog: UICatalog
## Sticky by default (matches ReselectButton); the corner button toggles it.
var auto_deselect := false
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
## Wall-clock of the last unit tap (view-side; not sim state) for double-tap.
var _last_tap_ms := 0
var _last_tap_pos := Vector2.ZERO


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
	# The held control modifier turns "replace the selection" into "add/remove"
	# and "issue an order" into "queue an order" (design.md "The control button").
	var control := hud.control_held()

	# Double-tap an own unit (no verb armed) grabs all of its type nearby;
	# with control held it toggles that type in/out of the selection instead.
	var now := Time.get_ticks_msec()
	var double := _armed.is_empty() and unit != null and unit.selectable \
			and now - _last_tap_ms <= DOUBLE_TAP_MS \
			and pos.distance_to(_last_tap_pos) <= DOUBLE_TAP_DIST
	_last_tap_ms = now
	_last_tap_pos = pos
	if double:
		if control:
			_toggle_type(unit, pos)
		else:
			_select(_same_type_near(unit, pos))
		return

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
		# Tapping an own unit re-selects; control held adds/removes it instead.
		if control:
			_toggle_unit(unit)
		else:
			_select([unit])
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
	if hits.is_empty():
		return
	if hud.control_held():
		# Control held: add the lassoed units to the selection (union).
		var union := selection.duplicate()
		for u in hits:
			if u not in union:
				union.append(u)
		_select(union)
	else:
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


## Clear the selection entirely (the control button's deselect-all petal).
func deselect_all() -> void:
	_select([])


## Add `unit` to the selection if absent, remove it if present (control+tap).
func _toggle_unit(unit: UnitView) -> void:
	var next := selection.duplicate()
	if unit in next:
		next.erase(unit)
	else:
		next.append(unit)
	_select(next)


## Toggle every own unit of `proto`'s type near the tap (control+double-tap):
## remove them all if all are already selected, otherwise add the missing ones.
func _toggle_type(proto: UnitView, pos: Vector2) -> void:
	var group := _same_type_near(proto, pos)
	var all_selected := true
	for u in group:
		if u not in selection:
			all_selected = false
			break
	var next := selection.duplicate()
	for u in group:
		if all_selected:
			next.erase(u)
		elif u not in next:
			next.append(u)
	_select(next)


## Every own selectable unit sharing `proto`'s type within a screen radius
## of `pos` (the second tap); at minimum the tapped unit itself.
func _same_type_near(proto: UnitView, pos: Vector2) -> Array[UnitView]:
	var hits: Array[UnitView] = []
	for u in _all_units():
		if not u.selectable or u.type_key != proto.type_key:
			continue
		if camera.is_position_behind(u.global_position):
			continue
		if camera.unproject_position(u.global_position).distance_to(pos) \
				<= SAME_TYPE_RADIUS_PX:
			hits.append(u)
	if hits.is_empty():
		hits.append(proto)
	return hits


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
