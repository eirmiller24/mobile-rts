extends Node3D
## Game root: owns the sim, drives it at a fixed tick rate, and assembles
## the M1 control prototype (HUD from the UI catalog, selection controller,
## dummy units). The view layer reads sim state; it never mutates it except
## through commands.

const TICK_DT := 1.0 / Sim.TICK_RATE

var sim: Sim
var catalog: UICatalog
var hud: Hud
var controller: SelectionController

var _accumulator := 0.0

@onready var camera_rig: CameraRig = $CameraRig
@onready var camera: Camera3D = $CameraRig/Camera3D


func _ready() -> void:
	sim = Sim.new(0xC0FFEE)
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
		_accumulator -= TICK_DT


func _spawn_demo_units() -> void:
	for i in 6:
		var pos := Vector3(-4.0 + 3.0 * (i % 3), 0.0, 5.0 + 3.0 * floori(i / 3.0))
		add_child(UnitView.make(UnitView.Kind.UNIT, UnitView.FACTION_PLAYER, pos))
	for i in 4:
		var pos := Vector3(-5.0 + 3.5 * i, 0.0, -14.0)
		add_child(UnitView.make(UnitView.Kind.UNIT, UnitView.FACTION_ENEMY, pos))
	for i in 3:
		var pos := Vector3(15.0, 0.0, -2.0 + 3.0 * i)
		add_child(UnitView.make(UnitView.Kind.RESOURCE, UnitView.FACTION_NEUTRAL, pos))


func _on_selection_changed(units: Array[UnitView]) -> void:
	hud.set_status("" if units.is_empty() else "%d selected" % units.size())


## M1 placeholder execution: orders just walk units around so the controls
## can be felt. M2 routes these through SimCommands instead.
func _on_order_issued(command_id: String, units: Array[UnitView],
		world_pos: Vector3, target: UnitView) -> void:
	for u in units:
		if not is_instance_valid(u):
			continue
		match command_id:
			"stop", "hold":
				u.order_stop()
			_:
				u.order_move(world_pos)
	OrderMarker.spawn(self, world_pos, catalog.command(command_id).color)
	var target_desc := "" if target == null else " (target: %s/%s)" % [
			UnitView.Kind.keys()[target.kind], target.faction]
	print("[order] %s x%d -> %v%s" % [command_id, units.size(), world_pos, target_desc])
