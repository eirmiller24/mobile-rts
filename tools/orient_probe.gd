extends SceneTree
## Report where each model's head bone sits in GODOT space.
##
## Godot's forward is -Z, so a correctly facing unit must have its head bone at
## NEGATIVE z. Positive z means the model faces backwards and will walk
## rear-first, because UnitView aims the node's -Z down the direction of travel.
##
##   godot --headless --path . -s res://tools/orient_probe.gd

func _initialize() -> void:
	for path in [
		"res://assets/models/Hive/hive_mite.glb",
		"res://assets/models/Hive/hive_spitter.glb",
		"res://assets/models/Hive/hive_lancer.glb",
		"res://assets/models/Hive/hive_carapace.glb",
		"res://assets/models/Hive/hive_laser_moth.glb",
	]:
		if not ResourceLoader.exists(path):
			print("MISSING ", path)
			continue
		var root := (ResourceLoader.load(path) as PackedScene).instantiate() as Node3D
		var skel := _find_skel(root)
		var fname: String = path.get_file()
		if skel == null:
			print("%-24s no skeleton" % fname)
			root.free()
			continue
		# Bone rest is skeleton-local, so it ignores any yaw the exporter baked
		# onto the root node. Compose the transforms up to the scene root —
		# that root-relative position is what actually decides which way the
		# unit faces once UnitView aims the node's -Z down its travel.
		var to_root := Transform3D.IDENTITY
		var n: Node = skel
		while n != null and n != root:
			to_root = (n as Node3D).transform * to_root
			n = n.get_parent()
		var head_z := NAN
		var head_name := ""
		for cand in ["head", "neck", "emitter", "thorax"]:
			var i := skel.find_bone(cand)
			if i >= 0:
				head_name = cand
				head_z = (to_root * skel.get_bone_global_rest(i).origin).z
				break
		# Also report the mesh AABB centre, as a second opinion.
		var mi := _find_mesh(root)
		var aabb_z := mi.get_aabb().get_center().z if mi != null else NAN
		var verdict := "FACES -Z (correct)" if head_z < 0.0 else "FACES +Z (BACKWARDS)"
		print("%-24s bone '%s' z=%+.3f  aabb_centre_z=%+.3f  %s"
				% [fname, head_name, head_z, aabb_z, verdict])
		root.free()
	quit(0)


func _find_skel(n: Node) -> Skeleton3D:
	if n is Skeleton3D:
		return n
	for c in n.get_children():
		var f := _find_skel(c)
		if f != null:
			return f
	return null


func _find_mesh(n: Node) -> MeshInstance3D:
	if n is MeshInstance3D:
		return n
	for c in n.get_children():
		var f := _find_mesh(c)
		if f != null:
			return f
	return null
