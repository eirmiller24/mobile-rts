extends SceneTree
## Headless performance check against the design budget: ~300 active units
## at a 20 Hz sim tick (50 ms per tick), pure GDScript. Spawns two armies on
## a 64x64-tile map with obstacles, marches them through each other with
## group orders, and reports tick timing for the worst phases (flow-field
## builds at order time, peak combat). Wall-clock here is measurement, not
## sim input — the sim itself never sees time.
##
## CI treats this as a smoke gate with generous headroom (runners are slow
## and shared); the printed numbers are the real product. Run on the host:
##   flatpak run org.godotengine.Godot --headless --path . \
##     -s res://tests/perf_check.gd

const UNITS_PER_SIDE := 150
const TICKS := 300
## Sim budget is 50 ms/tick; fail only beyond 4x to keep CI honest about
## catastrophes without flaking on slow runners.
const FAIL_AVG_MS := 200.0


func _initialize() -> void:
	var sim := TestSupport.sim(0xBEEF, 64, 64, [0, 1])
	var grunt := sim.catalog.key_of(TestSupport.GRUNT)

	# Scatter obstacles so pathing does real work.
	for i in 24:
		var cx := 16 + (i % 6) * 16
		var cy := 40 + (i / 6) * 12
		sim.spawn_resource(cx, cy, sim.catalog.key_of(TestSupport.ROCK))

	# A running economy alongside the melee (design_m3.md §8): 3 mining +
	# assisting hubs with deposits in range, a dozen structures, a growing
	# structure, and queues kept loaded for the whole run.
	var hub_key := sim.catalog.key_of(TestSupport.HUB)
	var hubs: Array[int] = []
	for i in 3:
		var hx := 16 + i * 40
		hubs.append(sim.spawn_structure(0, hx, 104, hub_key))
		sim.spawn_resource(hx + 8, 104, sim.catalog.key_of(TestSupport.NODE))
		sim.spawn_resource(hx - 6, 112, sim.catalog.key_of(TestSupport.NODE))
	sim.spawn_structure(0, 100, 110, hub_key, false) # growing, assist target
	for i in 12:
		sim.spawn_structure(0, 30 + i * 3, 118, sim.catalog.key_of(TestSupport.WALL))
	var seq := 0
	for i in hubs.size():
		var alloc := SimCommand.new(0, SimCommand.Kind.ALLOCATE_ECONOMY)
		alloc.targets = [hubs[i]]
		alloc.params = {"alloy": 20, "flux": 0, "assist": 10}
		alloc.seq = seq
		seq += 1
		sim.schedule(alloc)
		for t in range(0, TICKS, 20):
			var train := SimCommand.new(0, SimCommand.Kind.TRAIN)
			train.targets = [hubs[i]]
			train.params = {"type": grunt}
			train.seq = seq
			seq += 1
			sim.schedule(train, maxi(t, 4))

	var west: Array[int] = []
	var east: Array[int] = []
	for i in UNITS_PER_SIDE:
		west.append(sim.spawn_unit(0,
				Fixed.from_int(4 + (i % 10) * 2), Fixed.from_int(12 + (i / 10) * 3), grunt))
		east.append(sim.spawn_unit(1,
				Fixed.from_int(60 - (i % 10) * 2), Fixed.from_int(12 + (i / 10) * 3), grunt))

	var west_cmd := SimCommand.new(0, SimCommand.Kind.ATTACK_MOVE)
	west_cmd.targets = west
	west_cmd.params = {"x": Fixed.from_int(56), "y": Fixed.from_int(32)}
	sim.schedule(west_cmd)
	var east_cmd := SimCommand.new(1, SimCommand.Kind.ATTACK_MOVE)
	east_cmd.targets = east
	east_cmd.params = {"x": Fixed.from_int(8), "y": Fixed.from_int(32)}
	sim.schedule(east_cmd)

	var total_us := 0
	var worst_us := 0
	var worst_tick := -1
	for i in TICKS:
		var t0 := Time.get_ticks_usec()
		sim.step()
		var dt := Time.get_ticks_usec() - t0
		total_us += dt
		if dt > worst_us:
			worst_us = dt
			worst_tick = i
	var hash_t0 := Time.get_ticks_usec()
	var _h := sim.state_hash()
	var hash_us := Time.get_ticks_usec() - hash_t0

	var avg_ms := total_us / 1000.0 / TICKS
	var units_alive := 0
	for id in sim.entities:
		var e: SimEntity = sim.entities[id]
		if e.is_unit():
			units_alive += 1
	print("perf_check: %d units, %d ticks | avg %.2f ms/tick, worst %.2f ms (tick %d), state_hash %.2f ms | %d units alive"
			% [UNITS_PER_SIDE * 2, TICKS, avg_ms, worst_us / 1000.0, worst_tick, hash_us / 1000.0, units_alive])
	if avg_ms <= 50.0:
		print("perf_check: within the 50 ms / 20 Hz design budget")
	else:
		print("perf_check: OVER the 50 ms / 20 Hz design budget — profile before M3 piles on")

	if avg_ms > FAIL_AVG_MS:
		print("perf_check: FAILED (avg %.2f ms > %.2f ms hard ceiling)" % [avg_ms, FAIL_AVG_MS])
		quit(1)
	else:
		print("perf_check: OK")
		quit(0)
