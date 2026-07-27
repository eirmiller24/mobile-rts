extends SceneTree
## Render a catalog unit through the real UnitView path to PNGs, so a model's
## scale, facing and animation states can be eyeballed without launching a
## match. Development aid, not a test — view_model_check.gd is the check.
##
##   godot --path . -s res://tools/preview_unit.gd -- hive.mite .preview
##
## Drives the same code the game does: compiles the shipped catalog, builds a
## UnitView from its view block, and feeds it synthetic sim states (walking,
## then attacking) so the animation state machine is exercised for real.
##
## Needs a real display, so run it on the host — the devcontainer has no X11
## or Wayland client libraries and Godot cannot open a display server there.

const SIZE := Vector2i(480, 480)

var _shots: Array = []
var _view: UnitView
var _entity: SimEntity
var _frame := 0
var _out_dir := ".preview"


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	var type_id: String = args[0] if args.size() > 0 else "hive.mite"
	if args.size() > 1:
		_out_dir = args[1]
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://%s" % _out_dir))

	var layers: Array[Dictionary] = []
	for file in ["res://data/catalog/core.json", "res://data/catalog/hive.json"]:
		if FileAccess.file_exists(file):
			var parsed = JSON.parse_string(FileAccess.get_file_as_string(file))
			if typeof(parsed) == TYPE_DICTIONARY:
				layers.append(parsed)
	var catalog := CatalogCompiler.compile(layers)
	var key := catalog.key_of(type_id)
	if key < 0:
		push_error("unknown catalog type: %s" % type_id)
		quit(1)
		return
	var view_block := catalog.view_of(key)
	print("view block: ", view_block)

	var root := get_root()
	root.world_3d = World3D.new()

	var cam := Camera3D.new()
	cam.position = Vector3(1.5, 1.0, 1.9)
	cam.look_at_from_position(cam.position, Vector3(0, 0.4, 0), Vector3.UP)
	root.add_child(cam)
	cam.make_current()

	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-45, 35, 0)
	sun.light_energy = 2.5
	root.add_child(sun)
	var fill := DirectionalLight3D.new()
	fill.rotation_degrees = Vector3(-15, -140, 0)
	fill.light_energy = 1.0
	root.add_child(fill)

	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.16, 0.17, 0.19)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.5, 0.55, 0.6)
	env.ambient_light_energy = 0.8
	var we := WorldEnvironment.new()
	we.environment = env
	root.add_child(we)

	var floor_mesh := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(6, 6)
	var fm := StandardMaterial3D.new()
	fm.albedo_color = Color(0.30, 0.32, 0.34)
	plane.material = fm
	floor_mesh.mesh = plane
	root.add_child(floor_mesh)

	_entity = SimEntity.new()
	_entity.id = 1
	_entity.kind = SimEntity.Kind.UNIT
	_entity.type_key = key
	_entity.hp = 40
	_entity.max_hp = 40
	_entity.radius = Fixed.from_decimal("0.35")
	_entity.build_state = SimEntity.BuildState.COMPLETE

	_view = UnitView.from_entity(_entity, view_block, UnitView.FACTION_PLAYER, Vector3.ZERO)
	root.add_child(_view)

	# (label, sim dx per tick, cooldown) -- a walk, then a bite, then a rest.
	_shots = [
		["idle_a", 0.0, 0], ["idle_b", 0.0, 0],
		["run_a", 0.12, 0], ["run_b", 0.12, 0], ["run_c", 0.12, 0], ["run_d", 0.12, 0],
		["attack_a", 0.0, 20], ["attack_b", 0.0, 19], ["attack_c", 0.0, 18],
	]
	print("previewing %s -> %s/" % [type_id, _out_dir])


func _process(_delta: float) -> bool:
	# Let the first frames settle so the AnimationPlayer is live.
	if _frame < 2:
		_frame += 1
		return false
	var i := _frame - 2
	if i >= _shots.size():
		return true

	var shot: Array = _shots[i]
	_entity.x += Fixed.from_float(shot[1])
	_entity.cooldown = shot[2]
	_view.sync_state(_entity, 0, null)
	_view.position = Vector3(0, 0, 0)   # keep it framed; facing still updates

	await (self as SceneTree).process_frame
	await (self as SceneTree).process_frame
	var img := get_root().get_texture().get_image()
	var path := "res://%s/godot_%s.png" % [_out_dir, shot[0]]
	img.save_png(path)
	print("  ", path)
	_frame += 1
	return false
