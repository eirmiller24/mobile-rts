extends Node3D
## Game root: owns the sim, drives it at a fixed tick rate, and assembles
## the HUD (from the UI catalog), selection controller, and unit views.
## The view layer reads sim state and renders it interpolated between
## ticks; it influences the sim exclusively by scheduling SimCommands.

const TICK_DT := 1.0 / Sim.TICK_RATE
const MAP_PATH := "res://maps/dev_arena.json"
const SIM_SEED := 0xC0FFEE

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

## Player 0 is reserved for neutral/hostile-neutral map objects (§3).
const LOCAL_PLAYER := 1

var sim: Sim
var map: MapData
var catalog: UICatalog
var hud: Hud
var controller: SelectionController
var designations: Designations
## The sim's origin is the map corner; the view keeps the map centered.
var world_offset := 32.0

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
	map = MapLoader.load_path(MAP_PATH)
	if not map.ok():
		for e in map.errors:
			push_error("map: %s" % e)
		return
	world_offset = map.tiles_w / 2.0
	sim = Sim.new(SIM_SEED, map.catalog, map)
	catalog = UICatalog.load_default()
	if catalog == null:
		push_error("UI catalog failed to load; controls disabled")
		return
	for problem in catalog.validate():
		push_error("UI catalog: %s" % problem)

	designations = Designations.new()
	hud = Hud.new()
	hud.catalog = catalog
	hud.designations = designations
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

	controller.long_pressed.connect(_on_ground_long_pressed)
	hud.designation_button.has_selection = func() -> bool:
		return not controller.selection.is_empty()
	hud.designation_button.assign_requested.connect(_on_designation_assign)
	hud.designation_button.recall_requested.connect(_on_designation_recall)
	hud.chips.chip_tapped.connect(_on_designation_recall)

	_sync_views()


func _process(delta: float) -> void:
	_accumulator += minf(delta, 0.25) # clamp away hitches/debugger pauses
	while _accumulator >= TICK_DT:
		sim.step()
		_capture_tick()
		_accumulator -= TICK_DT
	_interpolate_views(_accumulator / TICK_DT)


## Create views for sim entities that don't have one yet (map spawns at
## startup, trained units later). Placeholder primitives until the
## catalog-driven view layer lands (M3 step 9).
func _sync_views() -> void:
	for id in sim.entities:
		if _views.has(id):
			continue
		var e: SimEntity = sim.entities[id]
		var pos := _sim_to_view(e)
		var kind := UnitView.Kind.UNIT if e.is_unit() else UnitView.Kind.RESOURCE
		var view := UnitView.make(kind, _faction_of(e), pos)
		view.entity_id = id
		add_child(view)
		_views[id] = view
		_prev[id] = pos
		_cur[id] = pos


func _faction_of(e: SimEntity) -> int:
	if e.player == LOCAL_PLAYER:
		return UnitView.FACTION_PLAYER
	if e.is_resource():
		return UnitView.FACTION_NEUTRAL
	return UnitView.FACTION_ENEMY


## After each sim tick: roll interpolation targets, create views for new
## entities, and drop views whose entities died.
func _capture_tick() -> void:
	_sync_views()
	designations.prune(func(id: int) -> bool:
		var e: SimEntity = sim.entities.get(id)
		return e != null and e.hp > 0)
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
	return Vector3(Fixed.to_float(e.x) - world_offset, 0.0,
			Fixed.to_float(e.y) - world_offset)


func _on_selection_changed(units: Array[UnitView]) -> void:
	hud.set_status("" if units.is_empty() else "%d selected" % units.size())


# --- designations (design_m3.md §6.1) ------------------------------------------


func _on_ground_long_pressed(world_pos: Vector3) -> void:
	var slot := designations.add_location(
			Fixed.from_float(world_pos.x + world_offset),
			Fixed.from_float(world_pos.z + world_offset))
	hud.set_status("designated %s" % designations.entry(slot)["name"]
			if slot != -1 else "no free designation slots")


func _on_designation_assign(slot: int) -> void:
	var ids := _selected_entity_ids()
	var used := designations.assign_group(ids, slot)
	hud.set_status("%s = %d units" % [designations.entry(used)["name"], ids.size()]
			if used != -1 else "no free designation slots")


func _on_designation_recall(slot: int) -> void:
	var e: Variant = designations.entry(slot)
	if e == null:
		return
	if e["kind"] == "location":
		jump_camera_to_sim(e["x"], e["y"])
	else:
		var views: Array[UnitView] = []
		for id: int in e["ids"]:
			if _views.has(id):
				views.append(_views[id])
		if not views.is_empty():
			controller._select(views)


func _selected_entity_ids() -> Array[int]:
	var ids: Array[int] = []
	for u in controller.selection:
		if is_instance_valid(u) and u.entity_id > 0:
			ids.append(u.entity_id)
	ids.sort()
	return ids


func jump_camera_to_sim(x: int, y: int) -> void:
	camera_rig.position = Vector3(Fixed.to_float(x) - world_offset, 0.0,
			Fixed.to_float(y) - world_offset)


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
			"x": Fixed.from_float(world_pos.x + world_offset),
			"y": Fixed.from_float(world_pos.z + world_offset),
		}
	sim.schedule(cmd)

	OrderMarker.spawn(self, world_pos, catalog.command(command_id).color)
	var target_desc := "" if target == null else " (target: %s/%s)" % [
			UnitView.Kind.keys()[target.kind], target.faction]
	print("[order] %s x%d -> %v%s" % [command_id, ids.size(), world_pos, target_desc])
