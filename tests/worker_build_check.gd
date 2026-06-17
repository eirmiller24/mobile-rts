extends SceneTree
## Headless checks for the M4 worker build mechanic + drawn walls
## (design_m4.md §4 / §16): worker travels and raises a structure, pulling it
## off freezes the GROWING structure and a REPAIR-order resumes it, multi-
## builder acceleration drains resources, repair heals, the anti-construction
## armor multiplier, and the drawn-wall segment queue (stroke order, pending
## costs nothing, parallel drain, cancel leaves the built portion).
##
## Run on the host:
##   flatpak run org.godotengine.Godot --headless --path . \
##     -s res://tests/worker_build_check.gd

var failures := 0


func _initialize() -> void:
	_test_travel_and_build()
	_test_freeze_and_resume()
	_test_multi_builder_accel()
	_test_repair()
	_test_anti_construction_armor()
	_test_wall_order_and_charge()
	_test_wall_parallel()
	_test_wall_cancel()

	if failures == 0:
		print("worker_build_check: OK")
		quit(0)
	else:
		print("worker_build_check: FAILED (%d)" % failures)
		quit(1)


func _fail(msg: String) -> void:
	push_error(msg)
	failures += 1


func _expect(cond: bool, msg: String) -> void:
	if not cond:
		_fail(msg)


# --- fixture ------------------------------------------------------------------


func _layer() -> Dictionary:
	return {
		"core.classes": {
			"kind": "classes",
			"sim": {
				"attack_classes": ["claw", "acid", "shock"],
				"armor_classes": ["light", "armored", "structure", "construction"],
				"matrix": {
					"claw":  { "light": "1.0", "armored": "0.75", "structure": "0.75", "construction": "0.75" },
					"acid":  { "light": "0.75", "armored": "1.5", "structure": "1.25", "construction": "2.5" },
					"shock": { "light": "1.5", "armored": "1.0", "structure": "0.75", "construction": "1.75" }
				},
				"build_rate": "20.0", "repair_rate": "20.0",
				"max_builders": 3, "accel_cost_rate": "20.0",
				"wall_cost_alloy": 5
			}
		},
		"r.build": {
			"kind": "ability",
			"sim": {
				"ability_kind": "build", "mechanic": "worker",
				"structures": ["r.hut", "r.wall"]
			}
		},
		"r.worker": {
			"kind": "unit",
			"sim": {
				"hp": 60, "armor_class": "light",
				"radius": "0.4", "speed": "6.0", "sight": "30.0",
				"carry_capacity": 1, "build_rate": "20.0",
				"abilities": ["r.build"]
			}
		},
		"r.hut": {
			"kind": "structure",
			"sim": {
				"hp": 1000, "foot_w": 2, "foot_h": 2, "armor_class": "structure",
				"cost_alloy": 40, "build_time": "2.0", "sight": "5.0"
			}
		},
		"r.wall": {
			"kind": "structure",
			"sim": {
				"hp": 200, "foot_w": 1, "foot_h": 1, "armor_class": "structure",
				"cost_alloy": 5, "build_time": "1.0", "los_height": 2
			}
		},
		"r.acid": {
			"kind": "unit",
			"sim": {
				"hp": 80, "damage": 10, "attack_class": "acid", "armor_class": "armored",
				"radius": "0.4", "speed": "3.0", "attack_range": "5.0",
				"acquire_range": "8.0", "cooldown": "1.0", "sight": "10.0", "hits_air": true
			}
		},
	}


func _sim(start_alloy: int = 1000) -> Sim:
	var cat := CatalogCompiler.compile([_layer()])
	assert(cat.ok(), "worker build fixture catalog: %s" % [cat.errors])
	var map := MapData.blank(48, 48)
	map.players.append({"id": 1, "faction": "rebels",
			"start_alloy": start_alloy, "start_flux": 0})
	map.players.append({"id": 2, "faction": "hive",
			"start_alloy": 0, "start_flux": 0})
	map.rehash()
	return Sim.new(11, cat, map)


func _key(sim: Sim, id: String) -> int:
	return sim.catalog.key_of(id)


## Spawn a worker centered on a pathing cell (so it lines up with cell-based
## structure footprints).
func _worker(sim: Sim, cx: int, cy: int) -> SimEntity:
	return sim.entities[sim.spawn_unit(1, sim.grid.cell_center(cx),
			sim.grid.cell_center(cy), _key(sim, "r.worker"))]


func _find(sim: Sim, type_id: String) -> SimEntity:
	for id in sim._sorted_ids():
		var e: SimEntity = sim.entities[id]
		if sim.catalog.id_of(e.type_key) == type_id:
			return e
	return null


func _count(sim: Sim, type_id: String) -> int:
	var n := 0
	for id in sim.entities:
		if sim.catalog.id_of(sim.entities[id].type_key) == type_id:
			n += 1
	return n


func _build_cmd(sim: Sim, worker: SimEntity, type_id: String, cx: int, cy: int) -> void:
	var c := SimCommand.new(1, SimCommand.Kind.BUILD)
	c.targets = [worker.id]
	c.params = {"type": _key(sim, type_id), "cx": cx, "cy": cy}
	sim.schedule(c)


# --- tests --------------------------------------------------------------------


func _test_travel_and_build() -> void:
	var sim := _sim()
	var w := _worker(sim, 40, 40)
	# Warm up vision so the (post-init) worker's sight covers the build site —
	# a worker can only build on ground it can see (§4.1).
	for _t in Sim.VISION_PERIOD + 1:
		sim.step()
	# Build a hut a few cells away; the worker must walk there.
	_build_cmd(sim, w, "r.hut", 44, 44)
	for _t in 5:
		sim.step()
	var hut := _find(sim, "r.hut")
	_expect(hut != null, "hut spawned GROWING on the BUILD order")
	_expect(hut.build_state == SimEntity.BuildState.GROWING, "hut is GROWING")
	_expect(hut.needs_builder, "worker-built hut needs a builder")
	_expect(w.build_target == hut.id, "worker committed to the hut")
	_expect(sim.players[1].alloy == Fixed.from_int(960), "cost reserved at order (1000-40)")
	# Let the worker arrive and raise it to COMPLETE.
	for _t in 200:
		sim.step()
	_expect(hut.build_state == SimEntity.BuildState.COMPLETE, "hut completed")
	_expect(w.build_target == 0, "worker freed after completion")


func _test_freeze_and_resume() -> void:
	var sim := _sim()
	var w := _worker(sim, 30, 30)
	# Frozen GROWING hut next to the worker, builder assigned by hand.
	var hut: SimEntity = sim._spawn_structure_entity(1, 30, 32, _key(sim, "r.hut"), false, 0)
	hut.needs_builder = true
	w.build_target = hut.id
	for _t in 10:
		sim.step()
	var progressed: int = Fixed.from_int(sim.catalog.sim_of(hut.type_key)["build_time"]) - hut.build_ticks_left
	_expect(progressed > 0, "worker on site made progress")
	# Pull the worker off with a plain MOVE — construction freezes.
	var mv := SimCommand.new(1, SimCommand.Kind.MOVE)
	mv.targets = [w.id]
	mv.params = {"x": 10 * Fixed.ONE, "y": 10 * Fixed.ONE}
	sim.schedule(mv)
	for _t in Sim.COMMAND_DELAY + 1:
		sim.step()
	_expect(w.build_target == 0, "MOVE detaches the worker from the build")
	var frozen_at: int = hut.build_ticks_left
	for _t in 10:
		sim.step()
	_expect(hut.build_ticks_left == frozen_at, "construction frozen with no builder")
	# Resume via a REPAIR-style order on the GROWING structure.
	var rep := SimCommand.new(1, SimCommand.Kind.REPAIR)
	rep.targets = [w.id]
	rep.params = {"target": hut.id}
	sim.schedule(rep)
	for _t in 200:
		sim.step()
	_expect(hut.build_state == SimEntity.BuildState.COMPLETE, "build resumed to completion")


func _test_multi_builder_accel() -> void:
	# Two builders on one frozen site: first free, second drains accel_cost.
	var sim := _sim()
	var hut: SimEntity = sim._spawn_structure_entity(1, 30, 30, _key(sim, "r.hut"), false, 0)
	hut.needs_builder = true
	var w0 := _worker(sim, 29, 30)
	var w1 := _worker(sim, 33, 30)
	w0.build_target = hut.id
	w1.build_target = hut.id
	var left0: int = hut.build_ticks_left
	var alloy0: int = sim.players[1].alloy
	sim.step()
	# Both contribute (1.0/tick each => 2.0 total); the extra builder costs
	# accel_cost_rate (20.0/sec => 1.0 alloy/tick).
	_expect(left0 - hut.build_ticks_left == 2 * Fixed.ONE,
			"two builders double the progress (got %d)" % (left0 - hut.build_ticks_left))
	_expect(alloy0 - sim.players[1].alloy == Fixed.ONE,
			"the extra builder drained 1.0 alloy/tick (got %d)" % (alloy0 - sim.players[1].alloy))

	# With no funds the extra builder idles: only the free builder progresses.
	sim.players[1].alloy = 0
	var left1: int = hut.build_ticks_left
	sim.step()
	_expect(left1 - hut.build_ticks_left == Fixed.ONE,
			"broke: only the free builder progresses (got %d)" % (left1 - hut.build_ticks_left))


func _test_repair() -> void:
	var sim := _sim()
	var hut: SimEntity = sim.entities[sim.spawn_structure(1, 30, 30, _key(sim, "r.hut"))]
	hut.hp = 100  # damaged (max 1000)
	var w := _worker(sim, 29, 30)
	var rep := SimCommand.new(1, SimCommand.Kind.REPAIR)
	rep.targets = [w.id]
	rep.params = {"target": hut.id}
	sim.schedule(rep)
	for _t in 80:
		sim.step()
	_expect(hut.hp > 100, "worker repaired the damaged structure (hp now %d)" % hut.hp)


func _test_anti_construction_armor() -> void:
	var sim := _sim()
	var construction := sim.catalog.armor_classes.find("construction")
	var structure := sim.catalog.armor_classes.find("structure")
	# A GROWING structure presents `construction`; a COMPLETE one its own armor.
	var growing: SimEntity = sim._spawn_structure_entity(1, 30, 30, _key(sim, "r.hut"), false, 0)
	growing.needs_builder = true
	var complete: SimEntity = sim.entities[sim.spawn_structure(1, 36, 30, _key(sim, "r.hut"))]
	_expect(sim._eff_armor_class(growing) == construction, "growing presents construction armor")
	_expect(sim._eff_armor_class(complete) == structure, "complete presents its own armor")
	# Exact single hit: acid 10 vs construction (2.5x) = 25 to a GROWING hut.
	var atk: SimEntity = sim.entities[sim.spawn_unit(2, growing.x + 2 * Fixed.ONE, growing.y,
			_key(sim, "r.acid"))]
	atk.cooldown = 0
	atk.target_id = growing.id
	var hp0: int = growing.hp
	sim.step()
	_expect(hp0 - growing.hp == 25,
			"acid vs construction dealt 25 (10 * 2.5), got %d" % (hp0 - growing.hp))


# --- drawn walls --------------------------------------------------------------


func _wall_cells(sim: Sim, cells: Array[int]) -> void:
	var c := SimCommand.new(1, SimCommand.Kind.BUILD_WALL)
	c.params = {"type": _key(sim, "r.wall"), "cells": cells}
	sim.schedule(c)


func _cell(sim: Sim, cx: int, cy: int) -> int:
	return cy * sim.grid.width + cx


func _test_wall_order_and_charge() -> void:
	var sim := _sim()
	_worker(sim, 40, 60)
	var c0 := _cell(sim, 60, 60)
	var c1 := _cell(sim, 61, 60)
	var c2 := _cell(sim, 62, 60)
	_wall_cells(sim, [c0, c1, c2] as Array[int])
	for _t in Sim.COMMAND_DELAY + 1:
		sim.step()
	# Pending: nothing blocked, nothing charged yet.
	_expect(sim.players[1].wall_cells.size() == 3, "3 pending wall segments")
	_expect(not sim.grid.is_blocked(60, 60), "pending segment blocks nothing")
	_expect(sim.players[1].alloy == Fixed.from_int(1000), "pending segment costs nothing")
	# Worker walks to the first cell and starts it (charged then).
	for _t in 60:
		sim.step()
		if _count(sim, "r.wall") >= 1:
			break
	_expect(_count(sim, "r.wall") >= 1, "first segment started")
	_expect(sim.players[1].alloy == Fixed.from_int(995), "first segment charged 5 alloy")
	var first := _find(sim, "r.wall")
	_expect(first.foot_x == 60 and first.foot_y == 60, "stroke order: c0 raised first")


func _test_wall_parallel() -> void:
	var sim := _sim()
	_worker(sim, 58, 58)
	_worker(sim, 64, 58)
	var cells: Array[int] = [_cell(sim, 60, 60), _cell(sim, 61, 60), _cell(sim, 62, 60)]
	_wall_cells(sim, cells)
	var max_concurrent := 0
	for _t in 80:
		sim.step()
		max_concurrent = maxi(max_concurrent, _count(sim, "r.wall"))
	_expect(max_concurrent >= 2, "two workers drained the queue in parallel (peak %d)" % max_concurrent)


func _test_wall_cancel() -> void:
	var sim := _sim()
	_worker(sim, 40, 60)
	var cells: Array[int] = [_cell(sim, 60, 60), _cell(sim, 61, 60), _cell(sim, 62, 60)]
	_wall_cells(sim, cells)
	for _t in 60:
		sim.step()
		if _count(sim, "r.wall") >= 1:
			break
	var started := _count(sim, "r.wall")
	_expect(started >= 1, "at least one segment started before cancel")
	var alloy_before: int = sim.players[1].alloy
	var cancel := SimCommand.new(1, SimCommand.Kind.CANCEL)
	cancel.params = {"wall": true}
	sim.schedule(cancel)
	for _t in Sim.COMMAND_DELAY + 1:
		sim.step()
	_expect(sim.players[1].wall_cells.is_empty(), "cancel cleared the pending queue")
	_expect(_count(sim, "r.wall") == started, "already-built segments persist after cancel")
	# Nothing pending was ever charged, so the balance only moved while idle.
	_expect(sim.players[1].alloy == alloy_before, "no pending segment was charged")
