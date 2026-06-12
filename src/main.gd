extends Node3D
## Game root: owns the sim, drives it at a fixed tick rate, and assembles
## the HUD (from the UI catalog), selection controller, and unit views.
## The view layer reads sim state and renders it interpolated between
## ticks; it influences the sim exclusively by scheduling SimCommands.

const TICK_DT := 1.0 / Sim.TICK_RATE
const MAP_TILES := 64
## The sim's origin is the map corner; the view keeps the map centered.
const WORLD_OFFSET := MAP_TILES / 2.0

## Engine verbs the sim understands. The catalog binds buttons/taps to
## command ids; this table is the engine implementing those verbs, not a
## button binding (see design.md "UI as Data"). Verbs the sim can't express
## yet degrade gracefully: patrol/mine move (M3/M4), hold stops.
const VERB_KIND := {
	"move": SimCommand.Kind.MOVE,
	"patrol": SimCommand.Kind.MOVE,
	"mine": SimCommand.Kind.MOVE,
	"attack": SimCommand.Kind.ATTACK_MOVE,
	"attack_move": SimCommand.Kind.ATTACK_MOVE,
	"stop": SimCommand.Kind.STOP,
	"hold": SimCommand.Kind.STOP,
}

const LOCAL_PLAYER := 0
const ENEMY_PLAYER := 1
const NEUTRAL_PLAYER := 2

var sim: Sim
var catalog: UICatalog
var hud: Hud
var controller: SelectionController

var _accumulator := 0.0
var _cmd_seq := 0
## entity id -> UnitView, plus per-id previous/current sim positions for
## render interpolation between ticks.
var _views := {}
var _prev := {}
var _cur := {}

@onready var camera_rig: CameraRig = $CameraRig
@onready var camera: Camera3D = $CameraRig/Camera3D


func _ready() -> void:
	sim = Sim.new(0xC0FFEE, MAP_TILES, MAP_TILES)
	catalog = UICatalog.load_default()
	if catalog == null:
		push_error("UI catalog failed to load; controls disabled")
		return
	for problem in catalog.validate():
		push_error("UI catalog: %s" % problem)

	hud = Hud.new()
	hud.catalog = catalog
	add_child(hud)
	camera_rig.ui_occluder = hud.is_point_on_ui

	controller = SelectionController.new()
	controller.camera = camera
	controller.hud = hud
	controller.catalog = catalog
	add_child(controller)

	hud.command_chosen.connect(controller.choose_command)
	hud.reselect.reselect_requested.connect(controller.reselect)
	hud.reselect.auto_deselect_toggled.connect(
			func(enabled: bool) -> void: controller.auto_deselect = enabled)
	controller.selection_changed.connect(_on_selection_changed)
	controller.order_issued.connect(_on_order_issued)

	_spawn_demo_units()


func _process(delta: float) -> void:
	_accumulator += minf(delta, 0.25) # clamp away hitches/debugger pauses
	while _accumulator >= TICK_DT:
		sim.step()
		_capture_tick()
		_accumulator -= TICK_DT
	_interpolate_views(_accumulator / TICK_DT)


func _spawn_demo_units() -> void:
	for i in 6:
		var pos := Vector3(-4.0 + 3.0 * (i % 3), 0.0, 5.0 + 3.0 * floori(i / 3.0))
		_spawn_sim_unit(LOCAL_PLAYER, UnitView.FACTION_PLAYER, pos)
	for i in 4:
		var pos := Vector3(-5.0 + 3.5 * i, 0.0, -14.0)
		_spawn_sim_unit(ENEMY_PLAYER, UnitView.FACTION_ENEMY, pos)
	# Resource line (mineable in M3; solid scenery for now).
	for i in 3:
		_spawn_obstacle(Vector3(15.0, 0.0, -2.0 + 3.0 * i))
	for pos in _obstacle_course():
		_spawn_obstacle(pos)


## A pathing playground between the two squads: two staggered walls with
## gaps, an L-shaped pocket guarding the right route, and stray rocks.
## Cubes sit at 1.5 spacing = exactly 3 pathing cells, so rows fuse into
## continuous blockers.
func _obstacle_course() -> Array[Vector3]:
	var list: Array[Vector3] = []
	# Front wall (z = -1): gap in the middle, gap on the right.
	for i in 8:
		list.append(Vector3(-16.0 + 1.5 * i, 0.0, -1.0))
	for i in 6:
		list.append(Vector3(-1.5 + 1.5 * i, 0.0, -1.0))
	# Staggered back wall (z = -7): open at both ends, offset from the
	# front gaps so nothing is a straight shot.
	for i in 9:
		list.append(Vector3(-10.0 + 1.5 * i, 0.0, -7.0))
	# L-shaped pocket narrowing the right route into a choke.
	for i in 3:
		list.append(Vector3(9.0, 0.0, -3.0 - 1.5 * i))
	for i in 2:
		list.append(Vector3(10.5 + 1.5 * i, 0.0, -3.0))
	# Stray rocks on the flanks.
	list.append(Vector3(-13.0, 0.0, -10.0))
	list.append(Vector3(3.0, 0.0, -11.0))
	return list


## Immovable, untargetable 3x3-cell (1.5 world unit) blocker with a yellow
## cube view snapped to its sim footprint.
func _spawn_obstacle(pos: Vector3) -> void:
	var cx := sim.grid.cell_of(Fixed.from_float(pos.x + WORLD_OFFSET)) - 1
	var cy := sim.grid.cell_of(Fixed.from_float(pos.z + WORLD_OFFSET)) - 1
	var id := sim.spawn_structure(NEUTRAL_PLAYER, cx, cy, 3, 3, 200, 0, false)
	if id == 0:
		push_warning("obstacle at %v overlaps blocked cells; skipped" % pos)
		return
	var snap_pos := _sim_to_view(sim.entities[id])
	var view := UnitView.make(UnitView.Kind.RESOURCE, UnitView.FACTION_NEUTRAL, snap_pos)
	view.entity_id = id
	add_child(view)
	_views[id] = view
	_prev[id] = snap_pos
	_cur[id] = snap_pos


func _spawn_sim_unit(player: int, faction: int, pos: Vector3) -> void:
	var id := sim.spawn_unit(player,
			Fixed.from_float(pos.x + WORLD_OFFSET),
			Fixed.from_float(pos.z + WORLD_OFFSET))
	var view := UnitView.make(UnitView.Kind.UNIT, faction, pos)
	view.entity_id = id
	add_child(view)
	_views[id] = view
	_prev[id] = pos
	_cur[id] = pos


## After each sim tick: roll interpolation targets and drop views whose
## entities died.
func _capture_tick() -> void:
	for id in _views.keys():
		var e: SimEntity = sim.entities.get(id)
		if e == null:
			_views[id].queue_free()
			_views.erase(id)
			_prev.erase(id)
			_cur.erase(id)
			continue
		_prev[id] = _cur[id]
		_cur[id] = _sim_to_view(e)


func _interpolate_views(alpha: float) -> void:
	var t := clampf(alpha, 0.0, 1.0)
	for id in _views:
		_views[id].position = _prev[id].lerp(_cur[id], t)


func _sim_to_view(e: SimEntity) -> Vector3:
	return Vector3(Fixed.to_float(e.x) - WORLD_OFFSET, 0.0,
			Fixed.to_float(e.y) - WORLD_OFFSET)


func _on_selection_changed(units: Array[UnitView]) -> void:
	hud.set_status("" if units.is_empty() else "%d selected" % units.size())


func _on_order_issued(command_id: String, units: Array[UnitView],
		world_pos: Vector3, target: UnitView) -> void:
	var ids: Array[int] = []
	for u in units:
		if is_instance_valid(u) and u.entity_id > 0:
			ids.append(u.entity_id)
	ids.sort()
	if ids.is_empty():
		return
	var kind: SimCommand.Kind = VERB_KIND.get(command_id, SimCommand.Kind.MOVE)

	var cmd := SimCommand.new(LOCAL_PLAYER, kind)
	cmd.targets = ids
	cmd.seq = _cmd_seq
	_cmd_seq += 1
	if kind != SimCommand.Kind.STOP:
		cmd.params = {
			"x": Fixed.from_float(world_pos.x + WORLD_OFFSET),
			"y": Fixed.from_float(world_pos.z + WORLD_OFFSET),
		}
	sim.schedule(cmd)

	OrderMarker.spawn(self, world_pos, catalog.command(command_id).color)
	var target_desc := "" if target == null else " (target: %s/%s)" % [
			UnitView.Kind.keys()[target.kind], target.faction]
	print("[order] %s x%d -> %v%s" % [command_id, ids.size(), world_pos, target_desc])
