extends SceneTree
## Headless determinism check: run two sims with the same seed and command
## stream and assert their state hashes match at every step, then run a
## third with a different seed and assert it diverges. The scenario
## exercises every M2 system: flow-field and A* movement, wall building
## (grid blocking), collision, combat, and crit procs (ProcRng + DRng).
##
## Run on the host (Godot is not installed in the devcontainer):
##   flatpak run org.godotengine.Godot --headless --path . \
##     -s res://tests/determinism_check.gd

const SEED := 0xDEADBEEF
const TICKS := 400
const MAP_TILES := 32


func _initialize() -> void:
	var a := _run(SEED)
	var b := _run(SEED)
	var c := _run(SEED + 1)

	var failures := 0
	for i in TICKS:
		if a["hashes"][i] != b["hashes"][i]:
			push_error("desync at tick %d: %d != %d" % [i, a["hashes"][i], b["hashes"][i]])
			failures += 1
			break
	if a["hashes"] == c["hashes"]:
		push_error("different seeds produced identical state histories")
		failures += 1
	if a["units_alive"] >= 12:
		push_error("no unit died in %d ticks; combat system not exercised" % TICKS)
		failures += 1

	if failures == 0:
		print("determinism_check: OK (%d ticks, %d/12 units survived)"
				% [TICKS, a["units_alive"]])
		quit(0)
	else:
		print("determinism_check: FAILED")
		quit(1)


func _run(seed_value: int) -> Dictionary:
	var sim := TestSupport.sim(seed_value, MAP_TILES, MAP_TILES)
	var critter := sim.catalog.key_of(TestSupport.CRITTER)
	var grunt := sim.catalog.key_of(TestSupport.GRUNT)
	var wall_key := sim.catalog.key_of(TestSupport.WALL)

	# Two opposing squads either side of a wall with a gap. Squad A crits
	# (exercises the pseudo-random proc path inside the hashed state).
	var squad_a: Array[int] = []
	var squad_b: Array[int] = []
	for i in 6:
		squad_a.append(sim.spawn_unit(0,
				Fixed.from_int(6 + (i % 3) * 2), Fixed.from_int(14 + (i / 3) * 2),
				critter))
		squad_b.append(sim.spawn_unit(1,
				Fixed.from_int(24 + (i % 3) * 2), Fixed.from_int(14 + (i / 3) * 2),
				grunt))

	# Wall column at world x=16 (cell cx=32), gap at cy 30..33.
	for cy in range(20, 45):
		if cy >= 30 and cy <= 33:
			continue
		var wall := SimCommand.new(2, SimCommand.Kind.BUILD)
		wall.seq = cy
		wall.params = {"cx": 32, "cy": cy, "type": wall_key}
		sim.schedule(wall, 2)

	sim.schedule(_attack_move(0, squad_a, 26, 16), 5)
	sim.schedule(_attack_move(1, squad_b, 6, 16), 5)

	var hashes: Array[int] = []
	for i in TICKS:
		# Periodic small-group MOVE orders driven by the sim's own RNG:
		# identical per seed, divergent across seeds, and they exercise A*.
		if i % 50 == 25:
			var cmd := SimCommand.new(0, SimCommand.Kind.MOVE)
			cmd.seq = 1000 + i
			cmd.targets = [squad_a[sim.rng.randi_range(0, 5)]]
			cmd.params = {
				"x": Fixed.from_int(sim.rng.randi_range(2, MAP_TILES - 2)),
				"y": Fixed.from_int(sim.rng.randi_range(2, MAP_TILES - 2)),
			}
			sim.schedule(cmd)
		sim.step()
		hashes.append(sim.state_hash())

	var units_alive := 0
	for id in sim.entities:
		var e: SimEntity = sim.entities[id]
		if e.is_unit() and e.hp > 0:
			units_alive += 1
	return {"hashes": hashes, "units_alive": units_alive}


func _attack_move(player: int, ids: Array[int], x_tiles: int, y_tiles: int) -> SimCommand:
	var cmd := SimCommand.new(player, SimCommand.Kind.ATTACK_MOVE)
	cmd.targets = ids.duplicate()
	cmd.params = {"x": Fixed.from_int(x_tiles), "y": Fixed.from_int(y_tiles)}
	return cmd
