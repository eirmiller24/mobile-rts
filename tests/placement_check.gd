extends SceneTree
## Headless check for the placement ghost's client-side validity
## prediction (design_m3.md §6.4) — both placement paths share it, so it
## must agree with the sim's BUILD rules: green on free visible ground,
## red on visible blockers, amber over fog, vent rule for siphons, and
## capsule surcharge outside influence.
##
## Run on the host:
##   flatpak run org.godotengine.Godot --headless --path . \
##     -s res://tests/placement_check.gd

var failures := 0


func _fail(msg: String) -> void:
	push_error(msg)
	failures += 1


func _expect(cond: bool, msg: String) -> void:
	if not cond:
		_fail(msg)


func _initialize() -> void:
	var map := MapLoader.load_path("res://maps/dev_arena.json")
	var sim := Sim.new(3, map.catalog, map)
	sim.step() # the aura index is rebuilt per tick; evaluate after one
	var ghost := PlacementGhost.new()
	ghost.sim = sim
	ghost.local_player = 1
	ghost.world_offset = map.tiles_w / 2.0
	get_root().add_child(ghost)

	# Free, visible, inside influence: green, base cost only.
	ghost.set_type(map.catalog.key_of("hive.relay"))
	ghost.move_to_world(Vector3(-17.0, 0.0, -22.0)) # cells ~(30, 20)
	var v := ghost.evaluate()
	_expect(not v["blocked"] and not v["fogged"] and v["inside"],
			"free spot inside influence should be green (%s)" % [v])
	_expect("capsule" not in v["info"], "no surcharge inside influence")

	# On the stronghold's own footprint: visibly blocked.
	ghost.move_to_world(Vector3(-20.5, 0.0, -20.5))
	v = ghost.evaluate()
	_expect(v["blocked"], "stronghold footprint should be blocked")

	# Deep fog: amber, capsule surcharge shown, still placeable.
	ghost.move_to_world(Vector3(8.0, 0.0, 8.0)) # tile ~(40, 40), unseen
	v = ghost.evaluate()
	_expect(v["fogged"] and not v["blocked"] and not v["inside"],
			"fogged free ground should be amber-placeable (%s)" % [v])
	_expect("capsule" in v["info"], "outside influence shows the surcharge")

	# Siphon: red off-vent, green exactly on the vent.
	ghost.set_type(map.catalog.key_of("hive.siphon"))
	ghost.move_to_world(Vector3(-10.0, 0.0, -10.0))
	v = ghost.evaluate()
	_expect(v["blocked"], "siphon off-vent should be blocked")
	ghost.cx = 36
	ghost.cy = 36
	v = ghost.evaluate()
	_expect(not v["blocked"], "siphon exactly on the vent should be valid")

	# The prediction agrees with the sim: a BUILD at the green spot lands.
	var relay := map.catalog.key_of("hive.relay")
	var builder := sim.builder_for(1, relay)
	_expect(builder != 0, "stronghold should be able to build")
	var cmd := SimCommand.new(1, SimCommand.Kind.BUILD)
	cmd.targets = [builder]
	cmd.params = {"type": relay, "cx": 30, "cy": 20}
	sim.schedule(cmd)
	for i in 5:
		sim.step()
	var placed := false
	for id in sim.entities:
		var e: SimEntity = sim.entities[id]
		if map.catalog.id_of(e.type_key) == "hive.relay":
			placed = true
	_expect(placed, "the predicted-valid build should execute")

	if failures == 0:
		print("placement_check: OK")
		quit(0)
	else:
		print("placement_check: FAILED (%d)" % failures)
		quit(1)
