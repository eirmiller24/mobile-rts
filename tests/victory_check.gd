extends SceneTree
## Headless checks for the M4 town-hall elimination rule (design_m4.md §7 /
## §16): eliminated the tick the last COMPLETE is_main structure dies, an
## in-flight/GROWING replacement does not save you, a main that finishes
## after the latch does not un-eliminate, match-over fires with one survivor,
## and elimination latches and never un-sets.
##
## Run on the host:
##   flatpak run org.godotengine.Godot --headless --path . \
##     -s res://tests/victory_check.gd

var failures := 0


func _initialize() -> void:
	_test_elimination_and_match_over()
	_test_growing_replacement_does_not_save()
	_test_finish_after_latch_does_not_unset()

	if failures == 0:
		print("victory_check: OK")
		quit(0)
	else:
		print("victory_check: FAILED (%d)" % failures)
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
				"matrix": { "claw": { "light": "1.0", "structure": "1.0" } }
			}
		},
		"t.main": {
			"kind": "structure",
			"sim": {
				"hp": 100, "foot_w": 2, "foot_h": 2, "armor_class": "structure",
				"cost_alloy": 50, "build_time": "2.0", "is_main": true
			}
		},
	}


func _sim() -> Sim:
	var cat := CatalogCompiler.compile([_layer()])
	assert(cat.ok(), "victory fixture catalog: %s" % [cat.errors])
	var map := MapData.blank(32, 32)
	map.players.append({"id": 1, "faction": "a", "start_alloy": 0, "start_flux": 0})
	map.players.append({"id": 2, "faction": "b", "start_alloy": 0, "start_flux": 0})
	map.rehash()
	return Sim.new(3, cat, map)


func _key(sim: Sim, id: String) -> int:
	return sim.catalog.key_of(id)


func _test_elimination_and_match_over() -> void:
	var sim := _sim()
	sim.spawn_structure(1, 4, 4, _key(sim, "t.main"))
	var m2: SimEntity = sim.entities[sim.spawn_structure(2, 20, 20, _key(sim, "t.main"))]
	sim.step()
	_expect(not sim.match_result()["over"], "match not over while both mains stand")
	# Destroy player 2's only main.
	m2.hp = 0
	var kill_tick := sim.tick
	sim.step()
	var res := sim.match_result()
	_expect(sim.players[2].eliminated_tick == kill_tick,
			"player 2 eliminated the tick its main died (got %d, want %d)"
			% [sim.players[2].eliminated_tick, kill_tick])
	_expect(res["over"], "match over after one player eliminated")
	_expect(res["winner"] == 1, "the survivor (player 1) won")
	_expect(sim.players[1].eliminated_tick == -1, "the winner is not eliminated")
	# Latch: running on does not un-eliminate or change the winner.
	for _t in 20:
		sim.step()
	_expect(sim.players[2].eliminated_tick == kill_tick, "elimination tick latched")


func _test_growing_replacement_does_not_save() -> void:
	var sim := _sim()
	sim.spawn_structure(1, 4, 4, _key(sim, "t.main"))
	var m2: SimEntity = sim.entities[sim.spawn_structure(2, 20, 20, _key(sim, "t.main"))]
	# A GROWING (incomplete) second main for player 2 — does not count.
	sim.spawn_structure(2, 24, 24, _key(sim, "t.main"), false)
	sim.step()  # latch that player 2 has owned a complete main
	m2.hp = 0
	sim.step()
	_expect(sim.players[2].eliminated_tick != -1,
			"a GROWING replacement does not save the player")


func _test_finish_after_latch_does_not_unset() -> void:
	var sim := _sim()
	sim.spawn_structure(1, 4, 4, _key(sim, "t.main"))
	var m2: SimEntity = sim.entities[sim.spawn_structure(2, 20, 20, _key(sim, "t.main"))]
	# A nearly-finished GROWING replacement that will COMPLETE shortly.
	var repl: SimEntity = sim.entities[sim.spawn_structure(2, 24, 24, _key(sim, "t.main"), false)]
	sim.step()  # latch that player 2 has owned a complete main
	repl.build_ticks_left = Fixed.from_int(2)
	m2.hp = 0
	sim.step()
	var latch: int = sim.players[2].eliminated_tick
	_expect(latch != -1, "player eliminated when last complete main died")
	# Let the replacement complete.
	for _t in 5:
		sim.step()
	_expect(repl.build_state == SimEntity.BuildState.COMPLETE, "replacement finished")
	_expect(sim.players[2].eliminated_tick == latch,
			"a main finishing after the latch does not un-eliminate")
	_expect(sim.match_result()["over"], "match stays over")
