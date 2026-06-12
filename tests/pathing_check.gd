extends SceneTree
## Headless pathfinding/movement checks:
##  1. A single unit (A* path) routes around a wall through a gap, never
##     standing in a blocked cell, and arrives.
##  2. A group (shared flow field) all cross the same wall and complete
##     their orders (crowd arrival included).
##  3. A unit ordered across a sealed wall gives up instead of grinding
##     against it forever.
##
## Run on the host:
##   flatpak run org.godotengine.Godot --headless --path . \
##     -s res://tests/pathing_check.gd

const MAP_TILES := 16
const WALL_CY := 16 # wall row in pathing cells; world y in [8.0, 8.5]

var failures := 0


func _initialize() -> void:
	_test_single_unit_astar()
	_test_group_flow_field()
	_test_unreachable_gives_up()
	_test_cluster_around_blocked_goal()

	if failures == 0:
		print("pathing_check: OK")
		quit(0)
	else:
		print("pathing_check: FAILED (%d)" % failures)
		quit(1)


func _fail(msg: String) -> void:
	push_error(msg)
	failures += 1


## Wall across the map at WALL_CY with a 4-cell gap at cx 14..17 (2.0 world
## units — wider than one unit diameter, see design.md clearance note).
func _build_gapped_wall(sim: Sim) -> void:
	sim.spawn_structure(1, 0, WALL_CY, 14, 1, 200)
	sim.spawn_structure(1, 18, WALL_CY, 14, 1, 200)


func _move(player: int, ids: Array[int], x: int, y: int) -> SimCommand:
	var cmd := SimCommand.new(player, SimCommand.Kind.MOVE)
	cmd.targets = ids.duplicate()
	cmd.params = {"x": x, "y": y}
	return cmd


func _test_single_unit_astar() -> void:
	var sim := Sim.new(1, MAP_TILES, MAP_TILES)
	_build_gapped_wall(sim)
	var id := sim.spawn_unit(0, Fixed.from_int(8), Fixed.from_int(4))
	var goal_x := Fixed.from_int(8)
	var goal_y := Fixed.from_int(13)
	sim.schedule(_move(0, [id], goal_x, goal_y))

	var arrived := false
	for i in 600:
		sim.step()
		var e: SimEntity = sim.entities[id]
		if sim.grid.is_blocked_index(sim._cell_index_of(e)):
			_fail("single: unit center entered a blocked cell at tick %d" % i)
			return
		if absi(e.x - goal_x) < Fixed.ONE and absi(e.y - goal_y) < Fixed.ONE:
			arrived = true
			break
	if not arrived:
		_fail("single: unit never reached the far side of the wall")


func _test_group_flow_field() -> void:
	var sim := Sim.new(2, MAP_TILES, MAP_TILES)
	_build_gapped_wall(sim)
	var ids: Array[int] = []
	for i in 6:
		ids.append(sim.spawn_unit(0,
				Fixed.from_int(6 + (i % 3) * 2), Fixed.from_int(3 + i / 3)))
	sim.schedule(_move(0, ids, Fixed.from_int(8), Fixed.from_int(13)))

	for i in 800:
		sim.step()
		for id in ids:
			var e: SimEntity = sim.entities[id]
			if sim.grid.is_blocked_index(sim._cell_index_of(e)):
				_fail("group: unit %d center in a blocked cell at tick %d" % [id, i])
				return

	var wall_world_y := Fixed.from_int(8) + SimGrid.CELL
	for id in ids:
		var e: SimEntity = sim.entities[id]
		if not e.orders.is_empty():
			_fail("group: unit %d never completed its move order" % id)
		if e.y <= wall_world_y:
			_fail("group: unit %d never crossed the wall (y=%d)" % [id, e.y])


func _test_unreachable_gives_up() -> void:
	var sim := Sim.new(3, MAP_TILES, MAP_TILES)
	sim.spawn_structure(1, 0, WALL_CY, MAP_TILES * SimGrid.PATH_SUBDIV, 1, 200)
	var id := sim.spawn_unit(0, Fixed.from_int(8), Fixed.from_int(4))
	sim.schedule(_move(0, [id], Fixed.from_int(8), Fixed.from_int(13)))

	for i in 200:
		sim.step()
	var e: SimEntity = sim.entities[id]
	if not e.orders.is_empty():
		_fail("unreachable: order still active after 200 ticks")
	if e.y >= Fixed.from_int(8):
		_fail("unreachable: unit somehow crossed a sealed wall")


## Six units ordered onto a solid cube must pack around it inside the
## order's cluster radius — not chain outward in a line (each newcomer
## stopping at the tail of the queue).
func _test_cluster_around_blocked_goal() -> void:
	var sim := Sim.new(4, MAP_TILES, MAP_TILES)
	# 3x3-cell scenery cube (like the demo's resource cubes), center ~(8.25, 8.25).
	sim.spawn_structure(2, 15, 15, 3, 3, 200, 0, false)
	var goal_x := Fixed.from_float(8.25)
	var goal_y := Fixed.from_float(8.25)
	var ids: Array[int] = []
	for i in 6:
		ids.append(sim.spawn_unit(0,
				Fixed.from_int(3 + (i % 3) * 2), Fixed.from_int(3 + (i / 3) * 2)))
	sim.schedule(_move(0, ids, goal_x, goal_y))

	for i in 400:
		sim.step()

	# Cluster radius for 6 units of default radius 0.4:
	# ARRIVE (0.5) + diameter (0.8) * (isqrt(6) + 1) = 2.9 world, plus half
	# a diameter of slack — completed units get jostled outward a bit as
	# later arrivals pack in. A chain of 6 would reach ~4.3 and fail this.
	var diameter := 2 * (Fixed.ONE * 2 / 5)
	var limit := Sim.ARRIVE_DIST + diameter * 7 / 2
	var quads := {}
	for id in ids:
		var e: SimEntity = sim.entities[id]
		if not e.orders.is_empty():
			_fail("cluster: unit %d never completed its order" % id)
		var dist := Fixed.sqrt(
				Fixed.mul(e.x - goal_x, e.x - goal_x)
				+ Fixed.mul(e.y - goal_y, e.y - goal_y))
		if dist > limit:
			_fail("cluster: unit %d ended %.2f world units out (limit %.2f) — line, not cluster"
					% [id, Fixed.to_float(dist), Fixed.to_float(limit)])
		quads[Vector2i(1 if e.x >= goal_x else 0, 1 if e.y >= goal_y else 0)] = true
	# Surround slots must spread the group around the cube, not pile it on
	# the approach side: 6 units should occupy at least 3 of the 4
	# quadrants around the cube's center (a one-sided pile occupies 1-2).
	if quads.size() < 3:
		_fail("cluster: units occupy only %d quadrant(s) — hugging one side, not surrounding"
				% quads.size())
