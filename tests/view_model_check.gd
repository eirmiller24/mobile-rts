extends SceneTree
## Headless checks for catalog-driven unit models (design_m3.md §7.1).
##
## A missing .glb or a renamed animation clip does not crash the game — the
## view silently falls back to a coloured primitive — so nothing would catch
## the regression in play. This asserts the wiring instead: every catalog
## entry that names a `view.model` must resolve to a scene that actually
## contains the clips its `view.animations` block promises.
##
## Run headless:
##   godot --headless --path . -s res://tests/view_model_check.gd

const CATALOG_DIR := "res://data/catalog"

var failures := 0


func _initialize() -> void:
	_check_catalog_models()
	_check_mite_model()
	_check_facing_math()
	_check_animation_states()

	if failures == 0:
		print("view_model_check: OK")
		quit(0)
	else:
		print("view_model_check: FAILED (%d failures)" % failures)
		quit(1)


func _fail(msg: String) -> void:
	push_error(msg)
	failures += 1


func _expect(cond: bool, msg: String) -> void:
	if not cond:
		_fail(msg)


## Every `view.model` in the shipped catalogs loads, and every clip named in
## `view.animations` exists in it.
func _check_catalog_models() -> void:
	var checked := 0
	for file in _catalog_files():
		var text := FileAccess.get_file_as_string(file)
		var parsed = JSON.parse_string(text)
		if typeof(parsed) != TYPE_DICTIONARY:
			_fail("could not parse catalog %s" % file)
			continue
		for key: String in parsed.keys():
			var entry: Dictionary = parsed[key]
			var view: Dictionary = entry.get("view", {})
			var path: String = str(view.get("model", ""))
			if path == "":
				continue
			checked += 1
			if not ResourceLoader.exists(path):
				_fail("%s: view.model does not exist: %s" % [key, path])
				continue
			var packed := ResourceLoader.load(path) as PackedScene
			if packed == null:
				_fail("%s: view.model is not a PackedScene: %s" % [key, path])
				continue
			var root := packed.instantiate() as Node3D
			if root == null:
				_fail("%s: view.model root is not a Node3D" % key)
				continue
			var player := _find_anim_player(root)
			var clips: Dictionary = view.get("animations", {})
			if clips.is_empty():
				root.free()
				continue
			if player == null:
				_fail("%s: view.animations set but %s has no AnimationPlayer" % [key, path])
				root.free()
				continue
			for state: String in clips.keys():
				var clip: String = str(clips[state])
				_expect(player.has_animation(clip),
						"%s: animation '%s' -> clip '%s' missing from %s (has: %s)"
						% [key, state, clip, path, ", ".join(player.get_animation_list())])
			root.free()
	_expect(checked > 0, "no catalog entry declares a view.model — wiring lost?")


## The mite is the first modelled unit; assert the properties the view layer
## relies on rather than just that the file loads.
func _check_mite_model() -> void:
	var path := "res://assets/models/Hive/hive_mite.glb"
	if not ResourceLoader.exists(path):
		_fail("mite model missing: %s" % path)
		return
	var root := (ResourceLoader.load(path) as PackedScene).instantiate() as Node3D
	var player := _find_anim_player(root)
	if player == null:
		_fail("mite model has no AnimationPlayer")
		root.free()
		return

	# The rig must be skinned, or the animations move nothing.
	var skinned := _find_skinned_mesh(root)
	_expect(skinned != null, "mite model has no skinned MeshInstance3D")
	if skinned != null:
		_expect(skinned.skin != null, "mite mesh has no skin binding")

	# Authored at the catalog height so the view can instance it at scale 1.
	if skinned != null:
		var aabb := skinned.get_aabb()
		_expect(absf(aabb.size.y - 0.9) < 0.12,
				"mite model height %.3f is not ~0.9 (hive.mite's catalog height)"
				% aabb.size.y)

	for clip in ["Idle", "Run", "Attack"]:
		_expect(player.has_animation(clip), "mite model missing clip '%s'" % clip)
		if player.has_animation(clip):
			_expect(player.get_animation(clip).length > 0.0,
					"mite clip '%s' has zero length" % clip)
	root.free()


## Facing is derived, not stored in the sim, so the mapping is easy to get
## backwards — a sign slip points every unit away from where it is going.
## Assert the model's forward really lands on the requested direction.
func _check_facing_math() -> void:
	# (label, direction in view space, expected model-forward)
	var cases := [
		["+x", Vector3(1, 0, 0)],
		["-x", Vector3(-1, 0, 0)],
		["+z", Vector3(0, 0, 1)],
		["-z", Vector3(0, 0, -1)],
		["diagonal", Vector3(1, 0, 1).normalized()],
	]
	for case in cases:
		var dir: Vector3 = case[1]
		var yaw: float = UnitView._yaw_toward(dir.x, dir.z)
		# A node at this yaw points its -Z here:
		var forward := Basis(Vector3.UP, yaw) * Vector3(0, 0, -1)
		_expect(forward.distance_to(dir) < 0.001,
				"facing %s: yaw %.3f aims (%.3f, %.3f), wanted (%.3f, %.3f)"
				% [case[0], yaw, forward.x, forward.z, dir.x, dir.z])


## The animation state machine reads sim state only: movement from successive
## positions, an attack from a *rise* in the cooldown counter.
func _check_animation_states() -> void:
	var catalog: CompiledCatalog = _compile_shipped_catalog()
	if catalog == null:
		return
	var key := catalog.key_of("hive.mite")
	if key < 0:
		_fail("hive.mite missing from the compiled catalog")
		return

	var e := SimEntity.new()
	e.id = 1
	e.kind = SimEntity.Kind.UNIT
	e.type_key = key
	e.hp = 40
	e.max_hp = 40
	e.radius = Fixed.from_decimal("0.35")
	e.build_state = SimEntity.BuildState.COMPLETE

	var view := UnitView.from_entity(e, catalog.view_of(key),
			UnitView.FACTION_PLAYER, Vector3.ZERO)
	get_root().add_child(view)

	view.sync_state(e, 0, null)   # first tick only seeds the previous position
	view.sync_state(e, 0, null)
	_expect(view.anim_state() == UnitView.ANIM_IDLE,
			"standing still should idle, got '%s'" % view.anim_state())

	# anim_state() is only the view's own bookkeeping — assert the
	# AnimationPlayer really is running the clip. The view starts playback in
	# from_entity(), before the node enters the tree, so this is the check that
	# a silent no-op there would leave every unit frozen in its rest pose.
	var player := _find_anim_player(view)
	if player == null:
		_fail("mite UnitView built no AnimationPlayer")
		view.queue_free()
		return
	_expect(player.is_playing(), "AnimationPlayer is not playing after build")
	_expect(player.current_animation == "Idle",
			"expected the Idle clip to be current, got '%s'" % player.current_animation)

	# Walk in +x for a few ticks.
	for i in 3:
		e.x += Fixed.from_decimal("0.12")
		view.sync_state(e, 0, null)
	_expect(view.anim_state() == UnitView.ANIM_MOVE,
			"moving should play the move clip, got '%s'" % view.anim_state())
	_expect(player.current_animation == "Run",
			"expected the Run clip while moving, got '%s'" % player.current_animation)
	_expect(absf(angle_difference(view.facing_yaw(),
			UnitView._yaw_toward(1.0, 0.0))) < 0.01,
			"walking +x should face +x, yaw was %.3f" % view.facing_yaw())

	# Stop, then land a hit: sim.gd sets cooldown = cooldown_ticks on the tick
	# the attack fires, so the view sees the counter rise.
	view.sync_state(e, 0, null)
	view.sync_state(e, 0, null)
	_expect(view.anim_state() == UnitView.ANIM_IDLE,
			"stopping should return to idle, got '%s'" % view.anim_state())
	e.cooldown = 20
	view.sync_state(e, 0, null)
	_expect(view.anim_state() == UnitView.ANIM_ATTACK,
			"a cooldown rise should trigger the attack clip, got '%s'"
			% view.anim_state())

	# A *falling* cooldown is just the timer ticking down, not a new swing.
	e.cooldown = 19
	view.sync_state(e, 0, null)
	_expect(view.anim_state() == UnitView.ANIM_ATTACK,
			"attack should hold while the one-shot plays, got '%s'"
			% view.anim_state())

	# Facing an attack target beats facing the direction of travel.
	view.sync_state(e, 0, Vector3(0, 0, -5))
	_expect(absf(angle_difference(view.facing_yaw(),
			UnitView._yaw_toward(0.0, -1.0))) < 0.01,
			"should face its attack target, yaw was %.3f" % view.facing_yaw())

	view.queue_free()


func _compile_shipped_catalog() -> CompiledCatalog:
	var layers: Array[Dictionary] = []
	for file in _catalog_files():
		var parsed = JSON.parse_string(FileAccess.get_file_as_string(file))
		if typeof(parsed) == TYPE_DICTIONARY:
			layers.append(parsed)
	if layers.is_empty():
		_fail("no catalog layers to compile")
		return null
	return CatalogCompiler.compile(layers)


func _catalog_files() -> Array[String]:
	var out: Array[String] = []
	var dir := DirAccess.open(CATALOG_DIR)
	if dir == null:
		_fail("cannot open %s" % CATALOG_DIR)
		return out
	for name in dir.get_files():
		if name.ends_with(".json"):
			out.append("%s/%s" % [CATALOG_DIR, name])
	return out


func _find_anim_player(node: Node) -> AnimationPlayer:
	if node is AnimationPlayer:
		return node
	for child in node.get_children():
		var found := _find_anim_player(child)
		if found != null:
			return found
	return null


func _find_skinned_mesh(node: Node) -> MeshInstance3D:
	if node is MeshInstance3D and (node as MeshInstance3D).skin != null:
		return node
	for child in node.get_children():
		var found := _find_skinned_mesh(child)
		if found != null:
			return found
	return null
