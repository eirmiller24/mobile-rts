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


const M3_TICKS := 800
const M4_TICKS := 1000

var failures := 0


func _initialize() -> void:
	var a := _run(SEED)
	var b := _run(SEED)
	var c := _run(SEED + 1)

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

	_check_m3()
	_check_m4()

	if failures == 0:
		print("determinism_check: OK (%d ticks, %d/12 units survived; M3 %d ticks; M4 %d ticks)"
				% [TICKS, a["units_alive"], M3_TICKS, M4_TICKS])
		quit(0)
	else:
		print("determinism_check: FAILED")
		quit(1)


## The M4 scenario (design_m4.md §16): two factions on the 1v1 map, both
## economies running (Hive nanos + Rebel worker fleet), each driven by a
## seeded BotCommander (its commands enter the stream), played out — run
## twice from the same seed must produce identical hash streams. This is the
## canary for a new M4 field that was added to state but not to hash_into().
func _check_m4() -> void:
	var a := _run_m4()
	var b := _run_m4()
	for i in M4_TICKS:
		if a["hashes"][i] != b["hashes"][i]:
			push_error("M4 desync at tick %d: %d != %d"
					% [i, a["hashes"][i], b["hashes"][i]])
			failures += 1
			break
	if not a["harvested"]:
		push_error("M4: the Rebel workers never harvested")
		failures += 1
	if not a["produced"]:
		push_error("M4: a bot never trained a unit (production not exercised)")
		failures += 1


func _run_m4() -> Dictionary:
	var map := MapLoader.load_path("res://maps/dev_clash.json")
	assert(map.ok(), "dev_clash: %s" % [map.errors])
	# The clash map is faction-agnostic now (resources + start anchors); spawn
	# the canonical Hive-vs-Rebels loadouts before constructing the sim.
	MatchSetup.apply(map, MatchSetup.default_factions(map))
	assert(map.ok(), "match setup: %s" % [map.errors])
	var sim := Sim.new(SEED, map.catalog, map)
	var hive := _bot(sim, 1)
	var rebels := _bot(sim, 2)
	hive.scout_hints = [_main_pos(sim, 2)]
	rebels.scout_hints = [_main_pos(sim, 1)]
	var start_units := sim.entities.size()
	var hashes: Array[int] = []
	var harvested := false
	var produced := false
	for _i in M4_TICKS:
		hive.tick()
		rebels.tick()
		sim.step()
		hashes.append(sim.state_hash())
		for id in sim.entities:
			var e: SimEntity = sim.entities[id]
			if e.is_unit() and e.harvest_state == SimEntity.HarvestState.HARVESTING:
				harvested = true
		if sim.entities.size() > start_units:
			produced = true
	return {"hashes": hashes, "harvested": harvested, "produced": produced}


func _bot(sim: Sim, pid: int) -> BotCommander:
	return BotCommander.new(sim, pid, 0x5EED + pid)


func _main_pos(sim: Sim, pid: int) -> Array:
	for id in sim._sorted_ids():
		var e: SimEntity = sim.entities[id]
		if e.player == pid and e.kind == SimEntity.Kind.STRUCTURE \
				and sim.catalog.sim_of(e.type_key).get("is_main", false):
			return [e.x, e.y]
	return [0, 0]


## The M3 scenario (design_m3.md §8): real catalog and map — economy,
## builds into fog, training, abilities, and combat vs the dummies — run
## twice from the same seed must produce identical hash streams, with
## vision recompute ticks covered.
func _check_m3() -> void:
	var a := _run_m3(SEED)
	var b := _run_m3(SEED)
	for i in M3_TICKS:
		if a["hashes"][i] != b["hashes"][i]:
			push_error("M3 desync at tick %d" % i)
			failures += 1
			break
	if not a["fog_relay_done"]:
		push_error("M3: the fog-built relay never completed")
		failures += 1
	if not a["doomed_capsule_died"]:
		push_error("M3: the capsule sent onto the dummy survived")
		failures += 1
	if not a["trained"]:
		push_error("M3: training produced no units")
		failures += 1
	if not a["dummies_damaged"]:
		push_error("M3: the army never hurt the dummies")
		failures += 1


func _run_m3(seed_value: int) -> Dictionary:
	var map := MapLoader.load_path("res://maps/dev_arena.json")
	assert(map.ok())
	var sim := Sim.new(seed_value, map.catalog, map)
	var cat := sim.catalog
	var sh := _find_type(sim, "hive.stronghold")
	var seq := 0

	var schedule := func(kind: SimCommand.Kind, targets: Array,
			params: Dictionary, at: int) -> void:
		var cmd := SimCommand.new(1, kind)
		cmd.targets.assign(targets)
		cmd.params = params
		cmd.seq = seq
		seq += 1
		sim.schedule(cmd, at)

	# Lancer + carapace pre-spawned so the ability runtime is exercised
	# without waiting out their long train times.
	var lancer := sim.spawn_unit(1, Fixed.from_int(30), Fixed.from_int(30),
			cat.key_of("hive.lancer"))
	var carapace := sim.spawn_unit(1, Fixed.from_int(31), Fixed.from_int(31),
			cat.key_of("hive.carapace"))

	schedule.call(SimCommand.Kind.ALLOCATE_ECONOMY, [sh.id],
			{"alloy": 40, "flux": 0, "assist": 10}, 5)
	schedule.call(SimCommand.Kind.BUILD, [sh.id],
			{"type": cat.key_of("hive.relay"), "cx": 30, "cy": 20}, 8)
	schedule.call(SimCommand.Kind.BUILD, [sh.id],
			{"type": cat.key_of("hive.relay"), "cx": 60, "cy": 70}, 10)
	schedule.call(SimCommand.Kind.BUILD, [sh.id],
			{"type": cat.key_of("hive.relay"), "cx": 80, "cy": 80}, 10)
	schedule.call(SimCommand.Kind.BUILD, [sh.id],
			{"type": cat.key_of("hive.siphon"), "cx": 36, "cy": 36}, 12)
	schedule.call(SimCommand.Kind.SET_RALLY, [sh.id],
			{"x": Fixed.from_int(30), "y": Fixed.from_int(30)}, 14)
	schedule.call(SimCommand.Kind.TRAIN, [sh.id],
			{"type": cat.key_of("hive.mite")}, 20)
	# The builds above drained the bank; the spitter waits for mining
	# income (and spawns after the assault order, staying safe at rally).
	schedule.call(SimCommand.Kind.TRAIN, [sh.id],
			{"type": cat.key_of("hive.spitter")}, 250)
	schedule.call(SimCommand.Kind.ABILITY, [lancer],
			{"ability": cat.key_of("hive.burrow"),
				"x": Fixed.from_int(36), "y": Fixed.from_int(36)}, 30)
	schedule.call(SimCommand.Kind.ABILITY, [carapace],
			{"ability": cat.key_of("hive.root")}, 40)
	schedule.call(SimCommand.Kind.ABILITY, [carapace],
			{"ability": cat.key_of("hive.root")}, 120)

	var hashes: Array[int] = []
	var trained := false
	for i in M3_TICKS:
		if i == 440:
			# Before the assault (it may not survive it): the mite must
			# have trained by now; the spitter is checked at the end.
			trained = _find_type(sim, "hive.mite") != null
		if i == 450:
			# Everything the player owns attacks the dummy camp.
			var army: Array[int] = []
			for id in sim._sorted_ids():
				var e: SimEntity = sim.entities[id]
				if e.player == 1 and e.is_unit() and e.hp > 0:
					army.append(id)
			var atk := SimCommand.new(1, SimCommand.Kind.ATTACK_MOVE)
			atk.targets = army
			atk.params = {"x": Fixed.from_int(41), "y": Fixed.from_int(41)}
			atk.seq = seq
			seq += 1
			sim.schedule(atk)
		sim.step()
		hashes.append(sim.state_hash())

	var fog_relay: SimEntity = null
	for id in sim._sorted_ids():
		var e: SimEntity = sim.entities[id]
		if cat.id_of(e.type_key) == "hive.relay" and e.foot_x == 60:
			fog_relay = e
	var dummies_damaged := false
	var dummy_count := 0
	for id in sim.entities:
		var e: SimEntity = sim.entities[id]
		if e.player == 0 and e.kind == SimEntity.Kind.STRUCTURE:
			dummy_count += 1
			if e.hp < e.max_hp:
				dummies_damaged = true
	# The doomed capsule was player 1's structure at the dummy's cells; the
	# dummy itself (player 0) still standing there is fine.
	var doomed_alive := false
	for id in sim.entities:
		var e: SimEntity = sim.entities[id]
		if e.player == 1 and e.kind == SimEntity.Kind.STRUCTURE \
				and e.foot_x == 80 and e.foot_y == 80:
			doomed_alive = true
	return {
		"hashes": hashes,
		"fog_relay_done": fog_relay != null
				and fog_relay.build_state == SimEntity.BuildState.COMPLETE,
		"doomed_capsule_died": not doomed_alive,
		"trained": trained and _find_type(sim, "hive.spitter") != null,
		"dummies_damaged": dummies_damaged or dummy_count < 3,
	}


func _find_type(sim: Sim, type_id: String) -> SimEntity:
	for id in sim._sorted_ids():
		var e: SimEntity = sim.entities[id]
		if sim.catalog.id_of(e.type_key) == type_id:
			return e
	return null


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
		sim.spawn_structure(2, 32, cy, wall_key)

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
