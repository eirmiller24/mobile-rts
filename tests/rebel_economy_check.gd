extends SceneTree
## Headless checks for the M4 Rebel worker harvest economy (design_m4.md §3 /
## §16): exact harvest fill rate and capacity, depot deposit + conservation,
## throughput shared ascending-id, worker death drops carry, direct vent vs
## Refinery (rate + cap + linked vents), the dial reconcile (role counts,
## auto-replace, manual MINE nudge). The synthetic catalog below is tuned so
## harvest_rate is 1.0/tick and capacities are small whole numbers.
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
	_test_dial_reconcile_counts()
	_test_auto_replace()
	_test_mine_nudges_dial()

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


func _count_role(sim: Sim, role: int) -> int:
	var n := 0
	for id in sim.entities:
		var e: SimEntity = sim.entities[id]
		if e.is_unit() and sim._is_worker(e) and e.harvest_role == role:
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


func _test_dial_reconcile_counts() -> void:
	var sim := _sim()
	var hq: SimEntity = sim.entities[sim.spawn_structure(1, 10, 10, _key(sim, "r.hq"))]
	for i in 4:
		_worker_near(sim, hq, 5 + i, 0)
	# build_mine_ratio 0.5 -> reserve 2; alloy_flux_ratio 0.5 -> 1 alloy, 1 flux.
	var c := SimCommand.new(1, SimCommand.Kind.SET_ECONOMY)
	c.params = {"build_mine_ratio": Fixed.HALF, "alloy_flux_ratio": Fixed.HALF}
	sim.schedule(c)
	for _t in Sim.COMMAND_DELAY + 1:
		sim.step()
	_expect(_count_role(sim, 1) == 1, "1 alloy harvester (got %d)" % _count_role(sim, 1))
	_expect(_count_role(sim, 2) == 1, "1 flux harvester (got %d)" % _count_role(sim, 2))
	_expect(_count_role(sim, 0) == 2, "2 build-reserve (got %d)" % _count_role(sim, 0))


func _test_auto_replace() -> void:
	var sim := _sim(1000)
	var hq: SimEntity = sim.entities[sim.spawn_structure(1, 10, 10, _key(sim, "r.hq"))]
	_worker_near(sim, hq, 6, 0)
	_worker_near(sim, hq, 7, 0)
	var c := SimCommand.new(1, SimCommand.Kind.SET_ECONOMY)
	c.params = {"worker_target": 3}
	sim.schedule(c)
	for _t in Sim.COMMAND_DELAY + 1:
		sim.step()
	# Two live + one queued reaches the target of three.
	_expect(sim._queued_workers(1) == 1,
			"auto-replace queued one worker toward the target (got %d)"
			% sim._queued_workers(1))
	_expect(hq.train_queue.size() == 1, "the HQ holds the queued replacement")


func _test_mine_nudges_dial() -> void:
	var sim := _sim()
	var vent: SimEntity = sim.entities[sim.spawn_resource(20, 20, _key(sim, "r.vent"))]
	var w1 := _worker_near(sim, vent, 4, 0)
	_worker_near(sim, vent, 0, 4)  # a second worker so the share is 1/2
	var p: SimPlayer = sim.players[1]
	_expect(p.alloy_flux_ratio == Fixed.ONE, "ratio starts all-alloy")
	var c := SimCommand.new(1, SimCommand.Kind.MINE)
	c.targets = [w1.id]
	c.params = {"node": vent.id}
	sim.schedule(c)
	for _t in Sim.COMMAND_DELAY + 1:
		sim.step()
	# One of two workers ordered onto flux nudges the ratio down by 1/2.
	_expect(p.alloy_flux_ratio == Fixed.HALF,
			"MINE nudged alloy_flux_ratio to 0.5 (got %d)" % p.alloy_flux_ratio)
	# No per-unit pin (§3.2): the dial moved, so the reconcile now keeps one
	# flux harvester where the fleet was all-alloy before.
	_expect(_count_role(sim, 2) == 1,
			"the nudge produced one flux harvester (got %d)" % _count_role(sim, 2))
	_expect(w1 != null, "ordered worker still exists")
