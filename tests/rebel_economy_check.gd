extends SceneTree
## Headless checks for the M4 Rebel worker harvest economy (design_m4.md §3 /
## §16): exact harvest fill rate and capacity, depot deposit + conservation,
## throughput shared ascending-id, worker death drops carry, direct vent vs
## Refinery (rate + cap + linked vents), and the per-worker work_state model
## (§3.2): SET_ECONOMY reassigns the auto pool to the requested counts,
## saturation spreads harvesters across nodes, MINE re-enlists, a MOVE ejects
## to MANUAL, and auto-replace restores the dead worker's state. The synthetic
## catalog below is tuned so harvest_rate is 1.0/tick and caps are small.
##
## Run on the host:
##   flatpak run org.godotengine.Godot --headless --path . \
##     -s res://tests/rebel_economy_check.gd

var failures := 0


func _initialize() -> void:
	_test_fill_rate_and_cap()
	_test_full_loop_conservation()
	_test_throughput_shared()
	_test_worker_death_drops_carry()
	_test_direct_vent()
	_test_refinery()
	_test_split_reassign_counts()
	_test_saturation_spread()
	_test_auto_skips_unseen()
	_test_manual_eject()
	_test_auto_replace()
	_test_train_raises_target()
	_test_mine_reenlists()
	_test_per_stronghold_replenish()
	_test_homogeneous_fresh_assignment()
	_test_target_persists_through_death()
	_test_mine_repools_to_expansion()

	if failures == 0:
		print("rebel_economy_check: OK")
		quit(0)
	else:
		print("rebel_economy_check: FAILED (%d)" % failures)
		quit(1)


func _fail(msg: String) -> void:
	push_error(msg)
	failures += 1


func _expect(cond: bool, msg: String) -> void:
	if not cond:
		_fail(msg)


# --- fixture ------------------------------------------------------------------


## harvest_rate 20.0/sec => 1.0/tick; raw vent is half rate and half cap.
func _layer() -> Dictionary:
	return {
		"core.classes": {
			"kind": "classes",
			"sim": {
				"attack_classes": ["claw"],
				"armor_classes": ["light", "structure", "construction"],
				"matrix": { "claw": { "light": "1.0", "structure": "1.0", "construction": "1.0" } },
				"harvest_rate": "20.0",
				"raw_flux_rate": "0.5",
				"raw_flux_carry": "0.5",
				"refinery_radius": "10.0"
			}
		},
		"r.build": {
			"kind": "ability",
			"sim": {
				"ability_kind": "build", "mechanic": "worker",
				"structures": ["r.hq", "r.refinery"]
			}
		},
		"r.hq": {
			"kind": "structure",
			"sim": {
				"hp": 800, "foot_w": 4, "foot_h": 4, "armor_class": "structure",
				"cost_alloy": 100, "build_time": "1.0", "sight": "20.0",
				"bandwidth_provided": 50, "is_depot": true, "is_main": true,
				"trains": ["r.worker"]
			}
		},
		"r.refinery": {
			"kind": "structure",
			"sim": {
				"hp": 200, "foot_w": 2, "foot_h": 2, "armor_class": "structure",
				"cost_alloy": 50, "build_time": "1.0", "sight": "10.0",
				"is_refinery": true
			}
		},
		"r.worker": {
			"kind": "unit",
			"sim": {
				"hp": 60, "armor_class": "light",
				"radius": "0.4", "speed": "3.0", "sight": "8.0",
				"bandwidth": 1, "cost_alloy": 10, "train_time": "1.0",
				"carry_capacity": 5, "harvest_rate": "20.0", "build_rate": "20.0",
				"abilities": ["r.build"]
			}
		},
		"r.deposit": {
			"kind": "resource",
			"sim": { "resource": "alloy", "amount": 1000, "throughput": "100.0",
				"foot_w": 2, "foot_h": 2 }
		},
		"r.slow_deposit": {
			"kind": "resource",
			"sim": { "resource": "alloy", "amount": 1000, "throughput": "20.0",
				"foot_w": 2, "foot_h": 2 }
		},
		"r.vent": {
			"kind": "resource",
			"sim": { "resource": "flux", "amount": 1000, "throughput": "100.0",
				"foot_w": 2, "foot_h": 2 }
		},
	}


func _sim(start_alloy: int = 0) -> Sim:
	var cat := CatalogCompiler.compile([_layer()])
	assert(cat.ok(), "rebel economy fixture catalog: %s" % [cat.errors])
	var map := MapData.blank(48, 48)
	map.players.append({"id": 1, "faction": "rebels",
			"start_alloy": start_alloy, "start_flux": 0})
	map.rehash()
	return Sim.new(7, cat, map)


func _key(sim: Sim, id: String) -> int:
	return sim.catalog.key_of(id)


## Spawn a worker at a fixed-point world position offset (in tiles) from a
## reference entity's center.
func _worker_near(sim: Sim, ref: SimEntity, dx_tiles: int, dy_tiles: int) -> SimEntity:
	var x := ref.x + dx_tiles * Fixed.ONE
	var y := ref.y + dy_tiles * Fixed.ONE
	return sim.entities[sim.spawn_unit(1, x, y, _key(sim, "r.worker"))]


func _count_state(sim: Sim, state: int) -> int:
	var n := 0
	for id in sim.entities:
		var e: SimEntity = sim.entities[id]
		if e.is_unit() and sim._is_worker(e) and e.work_state == state:
			n += 1
	return n


# --- tests --------------------------------------------------------------------


func _test_fill_rate_and_cap() -> void:
	var sim := _sim()
	var dep: SimEntity = sim.entities[sim.spawn_resource(20, 20, _key(sim, "r.deposit"))]
	var w := _worker_near(sim, dep, 2, 0)
	# Force the worker straight into harvesting to assert the exact rate.
	w.harvest_state = SimEntity.HarvestState.HARVESTING
	w.assigned_source = dep.id
	var before: int = dep.amount
	for t in 5:
		sim.step()
		_expect(w.carry == Fixed.from_int(t + 1),
				"fill tick %d: carry %d want %d" % [t, w.carry, Fixed.from_int(t + 1)])
	# Capped at carry_capacity (5), then it switches to hauling.
	_expect(w.carry == Fixed.from_int(5), "carry capped at capacity")
	_expect(w.harvest_state == SimEntity.HarvestState.TO_DEPOT, "full worker hauls")
	_expect(before - dep.amount == Fixed.from_int(5), "deposit drained by exactly 5")
	_expect(w.carry_kind == CatalogSchema.ResourceKind.ALLOY, "carry kind is alloy")


func _test_full_loop_conservation() -> void:
	var sim := _sim()
	var hq: SimEntity = sim.entities[sim.spawn_structure(1, 10, 10, _key(sim, "r.hq"))]
	var dep: SimEntity = sim.entities[sim.spawn_resource(16, 12, _key(sim, "r.deposit"))]
	var w := _worker_near(sim, dep, 1, 0)
	var p: SimPlayer = sim.players[1]
	var start_amount: int = dep.amount
	for _t in 400:
		sim.step()
		# Invariant: every unit of alloy removed from the deposit is either
		# banked or in transit on the worker — nothing leaks or duplicates.
		var removed := start_amount - dep.amount
		_expect(p.alloy + w.carry == removed,
				"conservation: banked %d + carry %d != removed %d"
				% [p.alloy, w.carry, removed])
	_expect(p.alloy > 0, "worker actually banked alloy over 400 ticks")
	_expect(hq != null, "hq exists")


func _test_throughput_shared() -> void:
	var sim := _sim()
	# Node limited to 1.0/tick total; two workers both want 1.0/tick.
	var dep: SimEntity = sim.entities[sim.spawn_resource(20, 20, _key(sim, "r.slow_deposit"))]
	var w1 := _worker_near(sim, dep, 2, 0)
	var w2 := _worker_near(sim, dep, 0, 2)
	for w: SimEntity in [w1, w2]:
		w.harvest_state = SimEntity.HarvestState.HARVESTING
		w.assigned_source = dep.id
	sim.step()
	# Ascending id: w1 (lower id) takes the whole 1.0/tick, w2 gets nothing.
	_expect(w1.carry == Fixed.from_int(1), "low-id worker takes the throughput")
	_expect(w2.carry == 0, "high-id worker starved this tick (ascending-id share)")


func _test_worker_death_drops_carry() -> void:
	var sim := _sim()
	var w: SimEntity = sim.entities[sim.spawn_unit(1, 10 * Fixed.ONE, 10 * Fixed.ONE, _key(sim, "r.worker"))]
	w.carry = Fixed.from_int(3)
	w.carry_kind = CatalogSchema.ResourceKind.ALLOY
	w.hp = 0  # killed mid-carry
	var p: SimPlayer = sim.players[1]
	sim.step()
	_expect(p.alloy == 0, "dead worker's carry is never banked")
	_expect(not sim.entities.has(w.id), "dead worker reaped")


func _test_direct_vent() -> void:
	var sim := _sim()
	var vent: SimEntity = sim.entities[sim.spawn_resource(20, 20, _key(sim, "r.vent"))]
	var w := _worker_near(sim, vent, 2, 0)
	w.harvest_state = SimEntity.HarvestState.HARVESTING
	w.assigned_source = vent.id
	# Raw mining: 0.5/tick, capped at half capacity (2.5), and it's Flux.
	for _t in 5:
		sim.step()
	_expect(w.carry == Fixed.ONE * 5 / 2, "raw vent caps carry at 2.5 (half capacity)")
	_expect(w.harvest_state == SimEntity.HarvestState.TO_DEPOT, "raw-full worker hauls")
	_expect(w.carry_kind == CatalogSchema.ResourceKind.FLUX, "carry kind is flux")


func _test_refinery() -> void:
	var sim := _sim()
	var vent: SimEntity = sim.entities[sim.spawn_resource(24, 24, _key(sim, "r.vent"))]
	# Refinery near the vent (within refinery_radius 10) — auto-links at COMPLETE.
	var refi: SimEntity = sim.entities[sim.spawn_structure(1, 20, 24, _key(sim, "r.refinery"))]
	_expect(vent.id in refi.linked_vents, "refinery auto-linked the nearby vent")
	var w := _worker_near(sim, refi, 2, 0)
	w.harvest_state = SimEntity.HarvestState.HARVESTING
	w.assigned_source = refi.id
	var before: int = vent.amount
	for _t in 5:
		sim.step()
	# Full rate (1.0/tick) and full capacity (5), drawn down from the vent.
	_expect(w.carry == Fixed.from_int(5), "refinery fills to full capacity at full rate")
	_expect(before - vent.amount == Fixed.from_int(5), "refinery drew its linked vent down")
	_expect(w.carry_kind == CatalogSchema.ResourceKind.FLUX, "refinery carry is flux")


func _test_split_reassign_counts() -> void:
	var sim := _sim()
	var hq: SimEntity = sim.entities[sim.spawn_structure(1, 10, 10, _key(sim, "r.hq"))]
	for i in 4:
		_worker_near(sim, hq, 5 + i, 0)
	# Per stronghold now: target 4 workers, alloy_side 2 (of which 1 build), flux
	# side 2 (of which 1 build): expect 1 ALLOY_BUILD, 1 ALLOY, 1 FLUX, 1 FLUX_BUILD.
	var c := SimCommand.new(1, SimCommand.Kind.SET_ECONOMY)
	c.targets = [hq.id]
	c.params = {"worker_target": 4, "alloy_side": 2, "alloy_build": 1, "flux_build": 1}
	sim.schedule(c)
	for _t in Sim.COMMAND_DELAY + 1:
		sim.step()
	_expect(_count_state(sim, SimEntity.WorkState.ALLOY_BUILD) == 1,
			"1 alloy+build (got %d)" % _count_state(sim, SimEntity.WorkState.ALLOY_BUILD))
	_expect(_count_state(sim, SimEntity.WorkState.ALLOY) == 1,
			"1 alloy (got %d)" % _count_state(sim, SimEntity.WorkState.ALLOY))
	_expect(_count_state(sim, SimEntity.WorkState.FLUX) == 1,
			"1 flux (got %d)" % _count_state(sim, SimEntity.WorkState.FLUX))
	_expect(_count_state(sim, SimEntity.WorkState.FLUX_BUILD) == 1,
			"1 flux+build (got %d)" % _count_state(sim, SimEntity.WorkState.FLUX_BUILD))


func _test_saturation_spread() -> void:
	var sim := _sim()
	# Two slow deposits (throughput 1.0/tick ⇒ saturation cap 1 worker each).
	var d1: SimEntity = sim.entities[sim.spawn_resource(20, 20, _key(sim, "r.slow_deposit"))]
	var d2: SimEntity = sim.entities[sim.spawn_resource(28, 20, _key(sim, "r.slow_deposit"))]
	# Both workers spawn next to d1, both on Alloy — greedy-nearest would pile
	# them on d1; saturation must push the second onto d2.
	var w1 := _worker_near(sim, d1, 2, 0)
	var w2 := _worker_near(sim, d1, 1, 0)
	for w: SimEntity in [w1, w2]:
		w.work_state = SimEntity.WorkState.ALLOY
		w.harvest_state = SimEntity.HarvestState.IDLE
	# Reveal the deposits: auto-mining only picks nodes the player has seen.
	sim._recompute_vision()
	sim.step()
	_expect(w1.assigned_source != 0 and w2.assigned_source != 0,
			"both workers picked a deposit")
	_expect(w1.assigned_source != w2.assigned_source,
			"saturation spread the two workers across both deposits")
	_expect(d2.id in [w1.assigned_source, w2.assigned_source],
			"the second worker took the farther, unsaturated deposit")


func _test_auto_skips_unseen() -> void:
	var sim := _sim()
	# A seen deposit by the worker and an unseen one far outside its sight.
	var near: SimEntity = sim.entities[sim.spawn_resource(12, 10, _key(sim, "r.deposit"))]
	var far: SimEntity = sim.entities[sim.spawn_resource(44, 10, _key(sim, "r.deposit"))]
	var w: SimEntity = sim.entities[sim.spawn_unit(1, 10 * Fixed.ONE, 10 * Fixed.ONE, _key(sim, "r.worker"))]
	w.work_state = SimEntity.WorkState.ALLOY
	w.harvest_state = SimEntity.HarvestState.IDLE
	# Run past a vision recompute so the near deposit is discovered.
	for _t in 8:
		sim.step()
	var p: SimPlayer = sim.players[1]
	_expect(near.id in p.discovered_resources, "the in-sight deposit was discovered")
	_expect(not (far.id in p.discovered_resources),
			"the far deposit was never seen, so never discovered")
	_expect(w.assigned_source == near.id,
			"auto-mining took the seen deposit, never the unseen one (got %d)"
			% w.assigned_source)


func _test_manual_eject() -> void:
	var sim := _sim()
	var hq: SimEntity = sim.entities[sim.spawn_structure(1, 10, 10, _key(sim, "r.hq"))]
	sim.spawn_resource(16, 12, _key(sim, "r.deposit"))
	var w := _worker_near(sim, hq, 6, 0)
	w.work_state = SimEntity.WorkState.ALLOY
	# A player MOVE ejects the worker from the economy to MANUAL (§3.2).
	var c := SimCommand.new(1, SimCommand.Kind.MOVE)
	c.targets = [w.id]
	c.params = {"x": hq.x + 8 * Fixed.ONE, "y": hq.y}
	sim.schedule(c)
	for _t in Sim.COMMAND_DELAY + 5:
		sim.step()
	_expect(w.work_state == SimEntity.WorkState.MANUAL,
			"MOVE ejected the worker to MANUAL")
	_expect(w.assigned_source == 0,
			"the economy left the manual worker alone (no source assigned)")


func _test_auto_replace() -> void:
	var sim := _sim(1000)
	var hq: SimEntity = sim.entities[sim.spawn_structure(1, 10, 10, _key(sim, "r.hq"))]
	_worker_near(sim, hq, 6, 0)
	_worker_near(sim, hq, 7, 0)
	# Per-stronghold target now: keep 3 at this HQ.
	var c := SimCommand.new(1, SimCommand.Kind.SET_ECONOMY)
	c.targets = [hq.id]
	c.params = {"worker_target": 3}
	sim.schedule(c)
	for _t in Sim.COMMAND_DELAY + 1:
		sim.step()
	# Two live + one queued reaches the HQ's target of three.
	_expect(hq.worker_target == 3, "the HQ holds the keep-target")
	_expect(hq.train_queue.size() == 1, "the HQ queued one worker toward its target")


func _test_train_raises_target() -> void:
	var sim := _sim(1000)
	var hq: SimEntity = sim.entities[sim.spawn_structure(1, 10, 10, _key(sim, "r.hq"))]
	var before := hq.worker_target
	# A player-issued TRAIN of a worker bumps THAT stronghold's keep-target so the
	# new worker joins its pool (§3.2); auto-replace trains do not (see above).
	var c := SimCommand.new(1, SimCommand.Kind.TRAIN)
	c.targets = [hq.id]
	c.params = {"type": _key(sim, "r.worker")}
	sim.schedule(c)
	for _t in Sim.COMMAND_DELAY + 1:
		sim.step()
	_expect(hq.worker_target == before + 1,
			"player TRAIN of a worker raised the HQ keep-target (got %d, was %d)"
			% [hq.worker_target, before])


func _test_mine_reenlists() -> void:
	var sim := _sim()
	var vent: SimEntity = sim.entities[sim.spawn_resource(20, 20, _key(sim, "r.vent"))]
	var w1 := _worker_near(sim, vent, 4, 0)
	# Pulled out of the economy (as a MOVE would leave it), then told to mine.
	w1.work_state = SimEntity.WorkState.MANUAL
	var c := SimCommand.new(1, SimCommand.Kind.MINE)
	c.targets = [w1.id]
	c.params = {"node": vent.id}
	sim.schedule(c)
	for _t in Sim.COMMAND_DELAY + 1:
		sim.step()
	# MINE re-enlists the MANUAL worker onto the tapped resource's side (§3.2).
	_expect(w1.work_state == SimEntity.WorkState.FLUX,
			"MINE re-enlisted the worker onto Flux (got %d)" % w1.work_state)
	_expect(w1.assigned_source == vent.id, "MINE pinned the worker to the vent")


func _count_home(sim: Sim, depot_id: int) -> int:
	var n := 0
	for id in sim.entities:
		var e: SimEntity = sim.entities[id]
		if e.hp > 0 and sim._is_worker(e) and e.home_depot == depot_id:
			n += 1
	return n


func _set_economy(sim: Sim, depot: SimEntity, target: int, alloy: int,
		alloy_build: int, flux_build: int) -> void:
	var c := SimCommand.new(1, SimCommand.Kind.SET_ECONOMY)
	c.targets = [depot.id]
	c.params = {"worker_target": target, "alloy_side": alloy,
			"alloy_build": alloy_build, "flux_build": flux_build}
	sim.schedule(c)


## (1) Each stronghold replenishes toward ITS OWN target, training at itself.
func _test_per_stronghold_replenish() -> void:
	var sim := _sim(1000)
	var hq1: SimEntity = sim.entities[sim.spawn_structure(1, 8, 8, _key(sim, "r.hq"))]
	var hq2: SimEntity = sim.entities[sim.spawn_structure(1, 36, 36, _key(sim, "r.hq"))]
	_worker_near(sim, hq1, 6, 0)
	_worker_near(sim, hq2, 6, 0)
	_set_economy(sim, hq1, 2, 2, 0, 0)
	_set_economy(sim, hq2, 2, 2, 0, 0)
	for _t in 60:
		sim.step()
	_expect(_count_home(sim, hq1.id) == 2,
			"HQ1 filled to its own target of 2 (got %d)" % _count_home(sim, hq1.id))
	_expect(_count_home(sim, hq2.id) == 2,
			"HQ2 filled to its own target of 2 (got %d)" % _count_home(sim, hq2.id))


## (3) A homogeneous base (all one resource, >1 worker) grows new workers on the
## same side, not balancing them to the empty side.
func _test_homogeneous_fresh_assignment() -> void:
	var sim := _sim(1000)
	var hq: SimEntity = sim.entities[sim.spawn_structure(1, 10, 10, _key(sim, "r.hq"))]
	_worker_near(sim, hq, 6, 0)
	_worker_near(sim, hq, 7, 0)
	_set_economy(sim, hq, 2, 2, 0, 0)  # both on Alloy
	for _t in Sim.COMMAND_DELAY + 1:
		sim.step()
	# Hand-train a third worker at this all-Alloy base.
	var c := SimCommand.new(1, SimCommand.Kind.TRAIN)
	c.targets = [hq.id]
	c.params = {"type": _key(sim, "r.worker")}
	sim.schedule(c)
	for _t in Sim.COMMAND_DELAY + 1:
		sim.step()
	_expect(hq.worker_target == 3, "target grew to 3 (got %d)" % hq.worker_target)
	_expect(hq.eco_alloy == 3,
			"the homogeneous base grew on the Alloy side (eco_alloy %d)" % hq.eco_alloy)


## (4) The economy target is independent of the live worker count: losing every
## worker leaves the target and split untouched (the slider doesn't move).
func _test_target_persists_through_death() -> void:
	var sim := _sim(1000)
	var hq: SimEntity = sim.entities[sim.spawn_structure(1, 10, 10, _key(sim, "r.hq"))]
	var a := _worker_near(sim, hq, 6, 0)
	var b := _worker_near(sim, hq, 7, 0)
	_set_economy(sim, hq, 2, 1, 0, 0)  # 1 Alloy, 1 Flux
	for _t in Sim.COMMAND_DELAY + 1:
		sim.step()
	_expect(hq.worker_target == 2 and hq.eco_alloy == 1, "target/split applied")
	a.hp = 0
	b.hp = 0
	sim.step()
	_expect(hq.worker_target == 2,
			"killing every worker did not change the keep-target (got %d)" % hq.worker_target)
	_expect(hq.eco_alloy == 1,
			"the allocation persisted through total loss (eco_alloy %d)" % hq.eco_alloy)


## (2) A MINE order onto a node in another base's region moves the worker to that
## base's pool (so it mines and hauls there, not back across the map).
func _test_mine_repools_to_expansion() -> void:
	var sim := _sim()
	var hq1: SimEntity = sim.entities[sim.spawn_structure(1, 8, 8, _key(sim, "r.hq"))]
	var hq2: SimEntity = sim.entities[sim.spawn_structure(1, 36, 36, _key(sim, "r.hq"))]
	var node: SimEntity = sim.entities[sim.spawn_resource(38, 30, _key(sim, "r.deposit"))]
	var w := _worker_near(sim, hq1, 6, 0)
	sim.step()  # home depots assigned
	_expect(w.home_depot == hq1.id, "worker starts homed to HQ1 (got %d)" % w.home_depot)
	var c := SimCommand.new(1, SimCommand.Kind.MINE)
	c.targets = [w.id]
	c.params = {"node": node.id}
	sim.schedule(c)
	for _t in Sim.COMMAND_DELAY + 1:
		sim.step()
	_expect(w.home_depot == hq2.id,
			"MINE moved the worker to the expansion's pool (got %d)" % w.home_depot)
	_expect(w.assigned_source == node.id, "MINE pinned the worker to the node")
