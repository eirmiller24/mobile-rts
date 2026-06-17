extends SceneTree
## Headless checks for M4 Rebel vision identity (design_m4.md §6 / §16):
## height-gated wall occlusion (a Barricade hides a ground unit behind it,
## the viewer still sees up to its own wall, an aerial capsule over the wall
## stays visible), capsule detection (a detector reveals an enemy capsule
## through fog), and knowledge-gating (is_entity_visible drives order
## resolution) plus the attack-move-to-stale-position degrade.
##
## Run on the host:
##   flatpak run org.godotengine.Godot --headless --path . \
##     -s res://tests/fog_orders_check.gd

var failures := 0


func _initialize() -> void:
	_test_wall_occludes_ground()
	_test_aerial_seen_over_wall()
	_test_capsule_detection()
	_test_attack_move_to_stale_position()

	if failures == 0:
		print("fog_orders_check: OK")
		quit(0)
	else:
		print("fog_orders_check: FAILED (%d)" % failures)
		quit(1)


func _fail(msg: String) -> void:
	push_error(msg)
	failures += 1


func _expect(cond: bool, msg: String) -> void:
	if not cond:
		_fail(msg)


func _layer() -> Dictionary:
	return {
		"core.classes": {
			"kind": "classes",
			"sim": {
				"attack_classes": ["claw"],
				"armor_classes": ["light", "structure"],
				"matrix": { "claw": { "light": "1.0", "structure": "1.0" } },
				"capsule_time": "100.0", "capsule_hp": 50
			}
		},
		"t.grow": {
			"kind": "ability",
			"sim": { "ability_kind": "build", "mechanic": "capsule",
				"structures": ["t.nest"] }
		},
		"t.viewer": {
			"kind": "unit",
			"sim": {
				"hp": 100, "damage": 0, "armor_class": "light",
				"radius": "0.4", "speed": "3.0", "sight": "20.0"
			}
		},
		"t.watcher": {
			"kind": "unit",
			"sim": {
				"hp": 100, "damage": 0, "armor_class": "light",
				"radius": "0.4", "speed": "3.0", "sight": "18.0",
				"detects_capsules": true
			}
		},
		"t.grunt": {
			"kind": "unit",
			"sim": {
				"hp": 100, "damage": 5, "attack_class": "claw", "armor_class": "light",
				"radius": "0.4", "speed": "4.0", "attack_range": "0.5",
				"acquire_range": "6.0", "cooldown": "1.0", "sight": "8.0"
			}
		},
		"t.wall": {
			"kind": "structure",
			"sim": {
				"hp": 200, "foot_w": 1, "foot_h": 1, "armor_class": "structure",
				"build_time": "1.0", "los_height": 2
			}
		},
		"t.nest": {
			"kind": "structure",
			"sim": {
				"hp": 100, "foot_w": 2, "foot_h": 2, "armor_class": "structure",
				"build_time": "5.0", "capsule_cost_alloy": 0
			}
		},
	}


func _sim() -> Sim:
	var cat := CatalogCompiler.compile([_layer()])
	assert(cat.ok(), "fog fixture catalog: %s" % [cat.errors])
	var map := MapData.blank(40, 40)
	map.players.append({"id": 1, "faction": "a", "start_alloy": 100, "start_flux": 0})
	map.players.append({"id": 2, "faction": "b", "start_alloy": 100, "start_flux": 0})
	map.rehash()
	return Sim.new(9, cat, map)


func _key(sim: Sim, id: String) -> int:
	return sim.catalog.key_of(id)


func _unit(sim: Sim, player: int, type_id: String, tx: int, ty: int) -> SimEntity:
	return sim.entities[sim.spawn_unit(player, tx * Fixed.ONE, ty * Fixed.ONE, _key(sim, type_id))]


# --- tests --------------------------------------------------------------------


func _test_wall_occludes_ground() -> void:
	var sim := _sim()
	# Viewer at x=10, enemy ground unit at x=16, a wall on the line between.
	var viewer := _unit(sim, 1, "t.viewer", 10, 10)
	var enemy := _unit(sim, 2, "t.grunt", 16, 10)
	# Barricade at build tile 13 (cells 26..27, y cells 20..21), on the y=10 line.
	sim.spawn_structure(1, 26, 20, _key(sim, "t.wall"))
	for _t in Sim.VISION_PERIOD + 1:
		sim.step()
	_expect(not sim.is_entity_visible(1, enemy),
			"wall occludes the enemy ground unit directly behind it")
	# The viewer still sees up to and including its own wall's tile (13).
	_expect(sim.is_tile_visible(1, 13, 10), "viewer sees up to its own wall")
	# A tile just in front of the wall (toward the viewer) is visible...
	_expect(sim.is_tile_visible(1, 12, 10), "near side of the wall is lit")
	# ...and a tile in the shadow behind the wall is not.
	_expect(not sim.is_tile_visible(1, 16, 10), "ground behind the wall is shadowed")
	_expect(viewer != null, "viewer exists")


func _test_aerial_seen_over_wall() -> void:
	var sim := _sim()
	_unit(sim, 1, "t.viewer", 10, 10)
	sim.spawn_structure(1, 26, 20, _key(sim, "t.wall"))
	# An enemy capsule hovering beyond the wall, within the viewer's sight.
	sim.players[2].alloy = Fixed.from_int(100)
	# Spawn a capsule directly (outside-territory build path needs fog; here we
	# just place an aerial nest for player 2 behind the wall).
	sim._spawn_capsule(2, 30, 20, _key(sim, "t.nest"), 0)
	var cap: SimEntity = null
	for id in sim.entities:
		if sim.entities[id].is_aerial():
			cap = sim.entities[id]
	for _t in Sim.VISION_PERIOD + 1:
		sim.step()
	_expect(cap != null and cap.is_aerial(), "capsule is aerial")
	_expect(sim.is_entity_visible(1, cap),
			"an aerial capsule is seen over the wall (radius-only)")


func _test_capsule_detection() -> void:
	var sim := _sim()
	# A lone enemy capsule deep in fog (no friendly unit nearby).
	sim._spawn_capsule(2, 30, 30, _key(sim, "t.nest"), 0)
	var cap: SimEntity = null
	for id in sim.entities:
		if sim.entities[id].is_aerial():
			cap = sim.entities[id]
	# Without any detector, player 1 cannot see it.
	for _t in Sim.VISION_PERIOD + 1:
		sim.step()
	_expect(not sim.is_tile_visible(1, 30, 30),
			"capsule tile is fogged with no detector in range")
	# A Watcher (detects_capsules) placed in range reveals it.
	_unit(sim, 1, "t.watcher", 22, 30)
	for _t in Sim.VISION_PERIOD + 1:
		sim.step()
	_expect(sim.is_tile_visible(1, 30, 30),
			"the detector revealed the enemy capsule through fog")
	_expect(cap != null, "capsule exists")


func _test_attack_move_to_stale_position() -> void:
	var sim := _sim()
	var grunt := _unit(sim, 1, "t.grunt", 10, 10)
	# Attack-move toward a position where a target used to be (now empty): the
	# unit marches there, finds nothing, and holds (the degraded behavior an
	# attack on a lost/fogged target collapses to, §6.4).
	var c := SimCommand.new(1, SimCommand.Kind.ATTACK_MOVE)
	c.targets = [grunt.id]
	c.params = {"x": 30 * Fixed.ONE, "y": 10 * Fixed.ONE}
	sim.schedule(c)
	for _t in 200:
		sim.step()
	_expect(absi(grunt.x - 30 * Fixed.ONE) <= Sim.ARRIVE_DIST * 2,
			"unit marched to the last-known position")
	_expect(grunt.orders.is_empty(), "and holds there with nothing to fight")
	_expect(grunt.target_id == 0, "no phantom target acquired")
