extends SceneTree
## Headless checks for the M3 sim systems (design_m3.md §8): mining
## exactness and depletion, throughput caps, train/cancel/bandwidth/rally,
## vision-gated builds (inside, visibly-blocked, fogged-lost, hover),
## siphon+vent, blink and toggle_morph abilities, damage classes, and the
## feral damage_taken multiplier. Numbers are exact: the synthetic catalog
## below is tuned so every assertion is a golden value.
##
## Run on the host:
##   flatpak run org.godotengine.Godot --headless --path . \
##     -s res://tests/economy_check.gd

var failures := 0


func _initialize() -> void:
	_test_mining_and_depletion()
	_test_throughput_cap()
	_test_train_cancel_bandwidth_rally()
	_test_queue_cap()
	_test_build_paths()
	_test_capsule_hover_and_air_targeting()
	_test_siphon_vent()
	_test_blink()
	_test_toggle_morph()
	_test_damage_classes_and_feral()

	if failures == 0:
		print("economy_check: OK")
		quit(0)
	else:
		print("economy_check: FAILED (%d)" % failures)
		quit(1)


func _fail(msg: String) -> void:
	push_error(msg)
	failures += 1


func _expect(cond: bool, msg: String) -> void:
	if not cond:
		_fail(msg)


# --- fixture ------------------------------------------------------------------


## Catalog tuned for exact assertions: rates of 1.0/sec, fast build and
## capsule times, small deposit amounts.
func _layer() -> Dictionary:
	return {
		"core.classes": {
			"kind": "classes",
			"sim": {
				"attack_classes": ["claw", "acid"],
				"armor_classes": ["light", "armored", "structure"],
				"matrix": {
					"claw": { "light": "1.0", "armored": "0.5", "structure": "1.0" },
					"acid": { "light": "1.0", "armored": "1.5", "structure": "1.0" }
				},
				"capsule_time": "1.0",
				"capsule_hp": 40,
				"alloy_rate": "1.0",
				"flux_rate": "1.0",
				"assist_rate": "1.0",
				"repair_rate": "20.0"
			}
		},
		"e.dome": {
			"kind": "ability",
			"sim": {
				"ability_kind": "aura", "radius": "10.0",
				"affects": "own_structures", "flags": ["territory"],
				"modifiers": { "hp_regen": "2.0", "damage_taken": "1.0" }
			}
		},
		"e.grow": {
			"kind": "ability",
			"sim": {
				"ability_kind": "build", "mechanic": "capsule",
				"structures": ["e.hub", "e.tower", "e.siphon"]
			}
		},
		"e.blink": {
			"kind": "ability",
			"sim": {
				"ability_kind": "blink", "range": "6.0",
				"travel_time": "0.5", "cooldown_time": "5.0"
			}
		},
		"e.root": {
			"kind": "ability",
			"sim": {
				"ability_kind": "toggle_morph", "morph_time": "0.5",
				"morphed": {
					"speed": "0", "damage": 30, "attack_range": "4.0",
					"hits_air": true
				}
			}
		},
		"e.hub": {
			"kind": "structure",
			"sim": {
				"hp": 400, "foot_w": 4, "foot_h": 4, "armor_class": "structure",
				"cost_alloy": 100, "capsule_cost_alloy": 50, "build_time": "5.0",
				"sight": "20.0", "damage_taken": "1.5",
				"bandwidth_provided": 5, "nano_pool": 4,
				"default_allocation": "idle",
				"abilities": ["e.dome", "e.grow"],
				"trains": ["e.melee", "e.archer", "e.lurker", "e.shifter"]
			}
		},
		"e.tower": {
			"kind": "structure",
			"sim": {
				"hp": 100, "foot_w": 2, "foot_h": 2, "armor_class": "armored",
				"cost_alloy": 30, "capsule_cost_alloy": 20, "build_time": "2.0",
				"sight": "5.0", "damage_taken": "1.5"
			}
		},
		"e.siphon": {
			"kind": "structure",
			"sim": {
				"hp": 100, "foot_w": 2, "foot_h": 2, "armor_class": "structure",
				"cost_alloy": 40, "build_time": "1.0", "damage_taken": "1.5",
				"builds_on_vent": true
			}
		},
		"e.vent": {
			"kind": "resource",
			"sim": { "resource": "flux", "amount": 5, "throughput": "100.0",
				"foot_w": 2, "foot_h": 2 }
		},
		"e.lode": {
			"kind": "resource",
			"sim": { "resource": "alloy", "amount": 3, "throughput": "100.0",
				"foot_w": 2, "foot_h": 2 }
		},
		"e.slow_lode": {
			"kind": "resource",
			"sim": { "resource": "alloy", "amount": 1000, "throughput": "0.05",
				"foot_w": 2, "foot_h": 2 }
		},
		"e.melee": {
			"kind": "unit",
			"sim": {
				"hp": 60, "damage": 10, "attack_class": "claw", "armor_class": "light",
				"radius": "0.4", "speed": "3.0", "attack_range": "0.5",
				"acquire_range": "6.0", "cooldown": "1.0", "sight": "8.0",
				"bandwidth": 2, "cost_alloy": 10, "train_time": "1.0"
			}
		},
		"e.archer": {
			"kind": "unit",
			"sim": {
				"hp": 50, "damage": 10, "attack_class": "acid", "armor_class": "light",
				"radius": "0.4", "speed": "3.0", "attack_range": "5.0",
				"acquire_range": "6.0", "cooldown": "1.0", "sight": "8.0",
				"hits_air": true,
				"cost_alloy": 10, "cost_flux": 5, "train_time": "1.0"
			}
		},
		"e.lurker": {
			"extends": "e.melee",
			"sim": { "abilities": ["e.blink"] }
		},
		"e.shifter": {
			"extends": "e.melee",
			"sim": { "armor_class": "armored", "abilities": ["e.root"] }
		},
	}


## 32x32-tile map, player 1 (and 2) with 1000 alloy / 100 flux, one hub
## for player 1 at cells (4,4) — world center (3,3), dome radius 10,
## sight 20.
func _sim() -> Sim:
	var cat := CatalogCompiler.compile([_layer()])
	assert(cat.ok(), "economy fixture catalog: %s" % [cat.errors])
	var map := MapData.blank(32, 32)
	map.players.append({"id": 1, "faction": "t", "start_alloy": 1000, "start_flux": 100})
	map.players.append({"id": 2, "faction": "t", "start_alloy": 1000, "start_flux": 100})
	map.rehash()
	var sim := Sim.new(99, cat, map)
	sim.spawn_structure(1, 4, 4, cat.key_of("e.hub"))
	return sim


func _key(sim: Sim, id: String) -> int:
	return sim.catalog.key_of(id)


func _hub(sim: Sim) -> SimEntity:
	for id in sim.entities:
		if sim.catalog.id_of(sim.entities[id].type_key) == "e.hub":
			return sim.entities[id]
	return null


func _find(sim: Sim, type_id: String, skip: int = 0) -> SimEntity:
	for id in sim._sorted_ids():
		var e: SimEntity = sim.entities[id]
		if sim.catalog.id_of(e.type_key) == type_id:
			if skip == 0:
				return e
			skip -= 1
	return null


func _cmd(sim: Sim, player: int, kind: SimCommand.Kind, targets: Array[int],
		params: Dictionary, seq: int = 0, at: int = -1) -> void:
	var c := SimCommand.new(player, kind)
	c.targets = targets
	c.params = params
	c.seq = seq
	sim.schedule(c, at)


# --- economy ------------------------------------------------------------------


func _test_mining_and_depletion() -> void:
	var sim := _sim()
	var lode := sim.spawn_resource(12, 8, _key(sim, "e.lode"))
	var hub := _hub(sim)
	var p: SimPlayer = sim.players[1]
	_cmd(sim, 1, SimCommand.Kind.ALLOCATE_ECONOMY, [hub.id],
			{"alloy": 4, "flux": 0, "assist": 0})
	for i in 3:
		sim.step()
	var a0: int = p.alloy
	sim.step() # first economy tick with the allocation live
	# alloy_rate 1.0/sec -> 65536/20 = 3276 per nano-tick (truncating), x4.
	_expect(p.alloy - a0 == 13104, "one-tick income: got %d, want 13104" % (p.alloy - a0))
	_expect(sim.income[hub.id]["alloy"] == 13104, "income map disagrees")
	# Depletion + conservation: every fixed-point crumb of the deposit's
	# 3.0 alloy ends up in the player's balance, then income stops.
	for i in 40:
		sim.step()
	_expect(sim.entities[lode].amount == 0, "lode never depleted")
	_expect(p.alloy == a0 + Fixed.from_int(3),
			"conservation: got +%d, want +%d" % [p.alloy - a0, Fixed.from_int(3)])
	_expect(sim.income[hub.id]["alloy"] == 0, "income should stop at depletion")


func _test_throughput_cap() -> void:
	var sim := _sim()
	sim.spawn_resource(12, 8, _key(sim, "e.slow_lode"))
	var hub := _hub(sim)
	var p: SimPlayer = sim.players[1]
	_cmd(sim, 1, SimCommand.Kind.ALLOCATE_ECONOMY, [hub.id],
			{"alloy": 4, "flux": 0, "assist": 0})
	for i in 3:
		sim.step()
	var a0: int = p.alloy
	sim.step()
	# throughput 0.05/sec -> 3277/20 = 163 per tick, despite demand 13104.
	_expect(p.alloy - a0 == 163, "cap: got %d, want 163" % (p.alloy - a0))


# --- production ---------------------------------------------------------------


func _test_train_cancel_bandwidth_rally() -> void:
	var sim := _sim()
	var hub := _hub(sim)
	var p: SimPlayer = sim.players[1]
	var melee := _key(sim, "e.melee")
	var a0: int = p.alloy
	_cmd(sim, 1, SimCommand.Kind.SET_RALLY, [hub.id],
			{"x": Fixed.from_int(12), "y": Fixed.from_int(3)}, 0)
	# bandwidth 5 provided, melee costs 2: two fit, the third is rejected.
	for i in 3:
		_cmd(sim, 1, SimCommand.Kind.TRAIN, [hub.id], {"type": melee}, 1 + i)
	for i in 4:
		sim.step()
	_expect(hub.train_queue.size() == 2, "queue should hold 2, got %d" % hub.train_queue.size())
	_expect(sim.bandwidth_of(1)["used"] == 4, "queued trainees should reserve bandwidth")
	_expect(p.alloy == a0 - Fixed.from_int(20), "two trains charged")
	# Cancel the second: full refund.
	_cmd(sim, 1, SimCommand.Kind.CANCEL, [hub.id], {"index": 1}, 10)
	for i in 4:
		sim.step()
	_expect(hub.train_queue.size() == 1, "cancel should leave 1 queued")
	_expect(p.alloy == a0 - Fixed.from_int(10), "cancel should refund")
	# Head completes (train_time 1.0s = 20 ticks from exec) and walks to
	# the rally point.
	for i in 25:
		sim.step()
	var unit := _find(sim, "e.melee")
	_expect(unit != null, "trained unit never spawned")
	if unit != null:
		_expect(hub.train_queue.is_empty(), "queue should be empty")
		_expect(not unit.orders.is_empty() or unit.x > Fixed.from_int(5),
				"trained unit should be moving to the rally point")
		_expect(sim.bandwidth_of(1)["used"] == 2, "live unit holds its bandwidth")


func _test_queue_cap() -> void:
	var sim := _sim()
	var hub := _hub(sim)
	var p: SimPlayer = sim.players[1]
	var archer := _key(sim, "e.archer") # bandwidth 0: only the cap limits
	var a0: int = p.alloy
	for i in 7:
		_cmd(sim, 1, SimCommand.Kind.TRAIN, [hub.id], {"type": archer}, i)
	for i in 4:
		sim.step()
	_expect(hub.train_queue.size() == 5, "queue cap is 5, got %d" % hub.train_queue.size())
	_expect(p.alloy == a0 - Fixed.from_int(50), "only 5 trains should charge")


# --- builds (design_m3.md §4.5) -------------------------------------------------


func _test_build_paths() -> void:
	var sim := _sim()
	var hub := _hub(sim)
	var p: SimPlayer = sim.players[1]
	var tower := _key(sim, "e.tower")

	# Inside territory: charged base cost, GROWING immediately, no capsule.
	var a0: int = p.alloy
	_cmd(sim, 1, SimCommand.Kind.BUILD, [hub.id], {"type": tower, "cx": 14, "cy": 4}, 0)
	for i in 4:
		sim.step()
	var t1 := _find(sim, "e.tower")
	_expect(t1 != null and t1.build_state == SimEntity.BuildState.GROWING,
			"inside build should grow instantly")
	_expect(p.alloy == a0 - Fixed.from_int(30), "inside build costs 30")
	for i in 45:
		sim.step()
	_expect(t1.build_state == SimEntity.BuildState.COMPLETE, "tower never completed")
	_expect(t1.hp == t1.max_hp, "completed tower at full hp")
	_expect(sim.eff_damage_taken(t1) == Fixed.ONE,
			"tower inside the dome sheds the feral penalty")

	# Visibly blocked (on the hub's own footprint): silent no-op, no charge.
	var a1: int = p.alloy
	_cmd(sim, 1, SimCommand.Kind.BUILD, [hub.id], {"type": tower, "cx": 5, "cy": 5}, 1)
	for i in 4:
		sim.step()
	_expect(p.alloy == a1, "visibly-blocked build must not charge")

	# Outside territory but visible: capsule with surcharge.
	var a2: int = p.alloy
	_cmd(sim, 1, SimCommand.Kind.BUILD, [hub.id], {"type": tower, "cx": 40, "cy": 8}, 2)
	for i in 4:
		sim.step()
	_expect(p.alloy == a2 - Fixed.from_int(50), "outside build costs 30+20")
	var capsule := _find(sim, "e.tower", 1)
	_expect(capsule != null and capsule.build_state == SimEntity.BuildState.CAPSULE,
			"outside build should fly a capsule")
	for i in 70:
		sim.step()
	_expect(capsule.build_state == SimEntity.BuildState.COMPLETE,
			"capsule tower should land and finish")
	_expect(sim.eff_damage_taken(capsule) == Fixed.from_decimal("1.5"),
			"tower outside the dome stays feral")

	# Into fog onto occupied ground: capsule lost, nothing refunds.
	sim.spawn_resource(50, 50, _key(sim, "e.lode")) # fogged blocker
	var a3: int = p.alloy
	_cmd(sim, 1, SimCommand.Kind.BUILD, [hub.id], {"type": tower, "cx": 50, "cy": 50}, 3)
	for i in 4:
		sim.step()
	var doomed := _find(sim, "e.tower", 2)
	_expect(doomed != null and doomed.build_state == SimEntity.BuildState.CAPSULE,
			"fogged build should fly on faith")
	_expect(p.alloy == a3 - Fixed.from_int(50), "fogged build charged up front")
	var doomed_id: int = doomed.id if doomed != null else 0
	for i in 25:
		sim.step()
	_expect(not sim.entities.has(doomed_id), "capsule must die on a hidden blocker")
	_expect(p.alloy == a3 - Fixed.from_int(50), "the stake is lost, not refunded")


func _test_capsule_hover_and_air_targeting() -> void:
	var sim := _sim()
	var hub := _hub(sim)
	var tower := _key(sim, "e.tower")
	# An enemy melee stands on the fogged site: the capsule must hover
	# (units are not a static blocker), and the melee must be unable to
	# touch it (no hits_air).
	var blocker := sim.spawn_unit(2, Fixed.from_decimal("25.5"),
			Fixed.from_decimal("25.5"), _key(sim, "e.melee"))
	_cmd(sim, 1, SimCommand.Kind.BUILD, [hub.id], {"type": tower, "cx": 50, "cy": 50}, 0)
	for i in 30:
		sim.step()
	var capsule := _find(sim, "e.tower")
	_expect(capsule != null and capsule.build_state == SimEntity.BuildState.CAPSULE,
			"capsule should hover over units")
	_expect(capsule.hp == 40, "melee must not scratch an airborne capsule")
	_expect(sim.entities[blocker].target_id != capsule.id,
			"melee must never target the capsule")
	# An archer (hits_air) can: two hits of 10 x 1.5 (acid vs armored)
	# x 1.5 (feral) = 22 kill the 40 hp capsule.
	sim.spawn_unit(2, Fixed.from_int(24), Fixed.from_int(25), _key(sim, "e.archer"))
	var cap_id: int = capsule.id
	for i in 60:
		sim.step()
	_expect(not sim.entities.has(cap_id), "archer should shoot the capsule down")


func _test_siphon_vent() -> void:
	var sim := _sim()
	var hub := _hub(sim)
	var p: SimPlayer = sim.players[1]
	var vent_id := sim.spawn_resource(16, 16, _key(sim, "e.vent"))
	var siphon := _key(sim, "e.siphon")

	# Wrong placement (not exactly on the vent): no-op.
	var a0: int = p.alloy
	_cmd(sim, 1, SimCommand.Kind.BUILD, [hub.id], {"type": siphon, "cx": 17, "cy": 16}, 0)
	for i in 4:
		sim.step()
	_expect(p.alloy == a0, "off-vent siphon must not charge")

	# On the vent: builds, links, extracts on a flux allocation.
	_cmd(sim, 1, SimCommand.Kind.BUILD, [hub.id], {"type": siphon, "cx": 16, "cy": 16}, 1)
	for i in 30:
		sim.step()
	var s1 := _find(sim, "e.siphon")
	_expect(s1 != null and s1.build_state == SimEntity.BuildState.COMPLETE,
			"siphon should complete")
	_expect(s1 != null and s1.vent_id == vent_id, "siphon should link its vent")

	# A second siphon on the same vent is rejected.
	var a1: int = p.alloy
	_cmd(sim, 1, SimCommand.Kind.BUILD, [hub.id], {"type": siphon, "cx": 16, "cy": 16}, 2)
	for i in 4:
		sim.step()
	_expect(p.alloy == a1, "occupied vent must reject a second siphon")

	_cmd(sim, 1, SimCommand.Kind.ALLOCATE_ECONOMY, [hub.id],
			{"alloy": 0, "flux": 4, "assist": 0})
	for i in 3:
		sim.step()
	var f0: int = p.flux
	for i in 30:
		sim.step()
	_expect(p.flux == f0 + Fixed.from_int(5),
			"vent's 5.0 flux extracted exactly (got +%d)" % (p.flux - f0))
	_expect(sim.entities[vent_id].amount == 0, "vent should be empty")

	# Siphon dies -> the vent is buildable again.
	s1.hp = 0 # direct kill: the scenario tests the vent rule, not combat
	sim.step()
	var a2: int = p.alloy
	_cmd(sim, 1, SimCommand.Kind.BUILD, [hub.id], {"type": siphon, "cx": 16, "cy": 16}, 3)
	for i in 4:
		sim.step()
	_expect(p.alloy == a2 - Fixed.from_int(40), "freed vent should accept a new siphon")


# --- abilities (design_m3.md §4.8) ----------------------------------------------


func _test_blink() -> void:
	var sim := _sim()
	# The hub footprint (world 2..4 x 2..4) is the wall: burrow from its
	# left to its right — a pure teleport through a blocked footprint.
	var lurker_id := sim.spawn_unit(1, Fixed.from_int(1), Fixed.from_int(3),
			_key(sim, "e.lurker"))
	var enemy_id := sim.spawn_unit(2, Fixed.from_int(1), Fixed.from_decimal("5.5"),
			_key(sim, "e.melee"))
	var lurker: SimEntity = sim.entities[lurker_id]
	var blink := _key(sim, "e.blink")
	_cmd(sim, 1, SimCommand.Kind.ABILITY, [lurker_id],
			{"ability": blink, "x": Fixed.from_int(6), "y": Fixed.from_int(3)}, 0)
	for i in 4:
		sim.step()
	_expect(lurker.is_underground(), "lurker should be burrowing")
	sim.step()
	_expect(sim.entities[enemy_id].target_id != lurker_id,
			"underground units are untargetable")
	for i in 10:
		sim.step()
	_expect(not lurker.is_underground(), "lurker should have surfaced")
	_expect(lurker.x > Fixed.from_int(4), "lurker should be past the hub (x=%d)" % lurker.x)
	_expect(not sim.grid.is_blocked(sim.grid.cell_of(lurker.x), sim.grid.cell_of(lurker.y)),
			"lurker must not surface inside a blocked cell")
	_expect(lurker.ability_cooldowns.get(blink, 0) > 0, "burrow cooldown should be running")
	# Cooldown gates the second burrow.
	var x_before: int = lurker.x
	_cmd(sim, 1, SimCommand.Kind.ABILITY, [lurker_id],
			{"ability": blink, "x": Fixed.from_int(1), "y": Fixed.from_int(3)}, 1)
	for i in 6:
		sim.step()
	_expect(not lurker.is_underground() and lurker.x >= x_before,
			"cooldown should reject the second burrow")
	# Out-of-range burrow is rejected (range 6).
	for i in 110:
		sim.step() # cooldown expires (5s = 100 ticks)
	_cmd(sim, 1, SimCommand.Kind.ABILITY, [lurker_id],
			{"ability": blink, "x": Fixed.from_int(20), "y": Fixed.from_int(20)}, 2)
	for i in 4:
		sim.step()
	_expect(not lurker.is_underground(), "out-of-range burrow should be rejected")


func _test_toggle_morph() -> void:
	var sim := _sim()
	var sid := sim.spawn_unit(1, Fixed.from_int(10), Fixed.from_int(10),
			_key(sim, "e.shifter"))
	var s: SimEntity = sim.entities[sid]
	var root := _key(sim, "e.root")
	_cmd(sim, 1, SimCommand.Kind.ABILITY, [sid], {"ability": root}, 0)
	for i in 4:
		sim.step()
	_expect(s.morph_ticks_left > 0, "shifter should be morphing")
	for i in 12:
		sim.step()
	_expect(s.morphed, "shifter should be rooted")
	_expect(s.step == 0, "rooted form is immobile")
	_expect(s.damage == 30, "rooted damage override")
	_expect(s.attack_range == 4 * Fixed.ONE, "rooted range override")
	_expect(s.hits_air, "rooted form hits air")
	_cmd(sim, 1, SimCommand.Kind.ABILITY, [sid], {"ability": root}, 1)
	for i in 16:
		sim.step()
	_expect(not s.morphed, "shifter should unroot")
	_expect(s.damage == 10 and s.step == (3 * Fixed.ONE) / 20 and not s.hits_air,
			"unroot must restore catalog stats")


# --- damage classes (design_m3.md §2.6) ------------------------------------------


func _test_damage_classes_and_feral() -> void:
	var sim := _sim()
	# acid 10 vs armored: 15 per hit.
	var archer := sim.spawn_unit(1, Fixed.from_int(20), Fixed.from_int(5),
			_key(sim, "e.archer"))
	var shifter := sim.spawn_unit(2, Fixed.from_int(23), Fixed.from_int(5),
			_key(sim, "e.shifter"))
	# claw 10 vs armored: 5 per hit.
	var melee := sim.spawn_unit(1, Fixed.from_int(20), Fixed.from_int(25),
			_key(sim, "e.melee"))
	var shifter2 := sim.spawn_unit(2, Fixed.from_int(21), Fixed.from_int(25),
			_key(sim, "e.shifter"))
	_expect(_first_hit_delta(sim, shifter) == 15, "acid vs armored should hit for 15")
	_expect(_first_hit_delta(sim, shifter2) == 5, "claw vs armored should hit for 5")

	# acid 10 vs a feral armored structure: 10 x 1.5 x 1.5 = 22 (truncated).
	var sim2 := _sim()
	var tower_id := sim2.spawn_structure(2, 40, 8, _key(sim2, "e.tower"))
	sim2.spawn_unit(1, Fixed.from_int(18), Fixed.from_decimal("4.5"),
			_key(sim2, "e.archer"))
	_expect(_first_hit_delta(sim2, tower_id) == 22,
			"acid vs feral armored structure should hit for 22")


## Steps until the entity first loses hp; returns the delta.
func _first_hit_delta(sim: Sim, id: int) -> int:
	var e: SimEntity = sim.entities[id]
	var hp0 := e.hp
	for i in 100:
		sim.step()
		if e.hp != hp0:
			return hp0 - e.hp
	return 0
