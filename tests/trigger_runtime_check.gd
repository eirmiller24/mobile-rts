extends SceneTree
## The C++ trigger VM, end to end (design_m5.md §7 trigger_runtime_check +
## trigger_determinism_check). Compiles Lua-flavored scripts, loads them into the
## native sim, and asserts: match_start fires and mutates the match; create_unit /
## resources / presentation work; every() fires on schedule; `wait` suspends and
## resumes with restored locals; overlapping waits keep independent per-instance
## state (the MUI proof, exit criterion 4); and the whole thing is deterministic
## (two runs from one seed -> identical hash every tick, exit criterion 3/8).
##
## Skips cleanly (exit 0) if the native extension is not built.
##
## Run:
##   godot --headless --path . -s res://tests/trigger_runtime_check.gd

var failures := 0


func _initialize() -> void:
	if not ClassDB.class_exists("NativeSim"):
		print("trigger_runtime_check: SKIP (NativeSim not built)")
		quit(0)
		return

	_test_match_start()
	_test_every_and_wait_mui()
	_test_unit_dies()
	_test_region_events()
	_test_determinism()
	_test_op_budget_no_hang()

	if failures == 0:
		print("trigger_runtime_check: OK")
		quit(0)
	else:
		print("trigger_runtime_check: FAILED (%d)" % failures)
		quit(1)


func _fail(msg: String) -> void:
	push_error(msg)
	print("  FAIL: ", msg)
	failures += 1


func _map() -> MapData:
	var m := MapData.blank(48, 48)
	m.players.append({"id": 1, "faction": "test", "start_alloy": 100000, "start_flux": 100000})
	m.players.append({"id": 2, "faction": "test", "start_alloy": 100000, "start_flux": 100000})
	m.rehash()
	return m


func _sim(seed_value: int, src: String, regions := [], region_names := {}) -> Object:
	var cat := TestSupport.catalog()
	var prog := TriggerCompiler.compile(src, cat, region_names)
	if not prog.ok():
		_fail("script failed to compile: %s" % str(prog.errors))
		return null
	var m := _map()
	for r: Dictionary in regions:
		m.regions.append(r)
	m.rehash()
	var nat: Object = ClassDB.instantiate("NativeSim")
	nat.construct(seed_value, cat, m)
	nat.load_triggers(prog)
	return nat


# --- match_start mutates the match; create_unit + presentation work. ---
func _test_match_start() -> void:
	var src := """
on match_start
	create_unit(t.grunt, PLAYER_2, point(10, 10))
	set_resource(PLAYER_1, ALLOY, 777)
	display_message(PLAYER_1, "engage")
end
"""
	var nat := _sim(123, src)
	if nat == null:
		return
	nat.step()  # tick 0 -> match_start runs
	# A grunt was spawned for player 2.
	var snap: Dictionary = nat.view_snapshot(1)
	var ids: PackedInt32Array = snap.get("ids", PackedInt32Array())
	if ids.size() != 1:
		_fail("match_start create_unit: expected 1 entity, got %d" % ids.size())
	# Resource was set (god action).
	var res: Dictionary = nat.resources_of(1)
	if int(res.get("alloy", -1)) != 777:
		_fail("set_resource: expected 777, got %s" % str(res.get("alloy")))
	# Presentation message reached the unhashed view queue.
	var pres: Array = nat.trigger_presentation()
	if pres.size() != 1 or String(pres[0].get("text", "")) != "engage":
		_fail("display_message: presentation queue wrong: %s" % str(pres))
	# Draining empties the queue.
	if nat.trigger_presentation().size() != 0:
		_fail("presentation queue not cleared after drain")


# --- every() schedules; `wait` suspends/resumes; overlapping frames keep
#     independent locals (MUI). Each every-frame captures k=wave at fire time,
#     waits 10 ticks, then credits ALLOY by *its own* k. If locals collided the
#     credited total would be wrong; we assert the exact MUI total. ---
func _test_every_and_wait_mui() -> void:
	var src := """
globals
	wave: int = 0
end

on every(2)
	wave = wave + 1
	local k: int = wave
	wait(10)
	add_resource(PLAYER_1, ALLOY, k)
end
"""
	var nat := _sim(999, src)
	if nat == null:
		return
	# Step through tick phases 0..30. every(2) fires at ticks 2,4,...; the frame
	# fired at tick X resumes at X+10 and credits k = X/2. By the phase at tick 30,
	# frames fired at X in [2..20] have resumed -> k in [1..10] -> sum 55.
	for i in 31:
		nat.step()
	var res: Dictionary = nat.resources_of(1)
	if int(res.get("alloy", -1)) != 100000 + 55:
		_fail("every+wait MUI: expected alloy 100055, got %s" % str(res.get("alloy")))


# --- unit_dies fires when a unit dies, with the dying unit readable in context. ---
func _test_unit_dies() -> void:
	var src := """
on match_start
	create_unit(t.grunt, PLAYER_2, point(10, 10))
end

on every(1)
	local g: group = units_of_player(PLAYER_2, ANY)
	for u in g do
		kill_unit(u)
	end
end

on unit_dies
	if owner(dying_unit()) == PLAYER_2 then
		add_resource(PLAYER_1, ALLOY, 100)
	end
end
"""
	var nat := _sim(7, src)
	if nat == null:
		return
	nat.step()  # tick 0: match_start spawns the grunt
	nat.step()  # tick 1: every kills it; _reap fires unit_dies -> +100
	nat.step()
	var res: Dictionary = nat.resources_of(1)
	if int(res.get("alloy", -1)) != 100000 + 100:
		_fail("unit_dies: expected alloy 100100, got %s" % str(res.get("alloy")))


# --- unit_enters_region fires once when a unit crosses into a named region. ---
func _test_region_events() -> void:
	var one := Fixed.ONE
	var regions := [{"id": 1, "min_x": 7 * one, "min_y": 7 * one,
			"max_x": 9 * one, "max_y": 9 * one}]
	var src := """
on match_start
	create_unit(t.grunt, PLAYER_1, point(2, 2))
end

on every(1)
	local g: group = units_of_player(PLAYER_1, ANY)
	for u in g do
		set_unit_position(u, point(8, 8))
	end
end

on unit_enters_region(zone)
	add_resource(PLAYER_1, FLUX, 50)
end
"""
	var nat := _sim(3, src, regions, {"zone": 1})
	if nat == null:
		return
	for i in 6:
		nat.step()
	var res: Dictionary = nat.resources_of(1)
	# Unit teleports inside on tick 1; check_regions detects the crossing and fires
	# exactly one enter (it stays inside thereafter -> no re-fire).
	if int(res.get("flux", -1)) != 100000 + 50:
		_fail("unit_enters_region: expected flux 100050, got %s" % str(res.get("flux")))


# --- Determinism: two native sims from one seed running the same script produce
#     identical state_hash() every tick (covers all hashed trigger state). ---
func _test_determinism() -> void:
	var src := """
globals
	n: int = 0
	g: group
end

function reinforce(p: player, count: int) -> group
	return create_units(count, t.grunt, p, point(20, 20))
end

on match_start
	g = reinforce(PLAYER_2, 4)
	for u in g do
		order_attack_move(u, point(5, 5))
	end
end

on every(3)
	n = n + 1
	local extra: group = reinforce(PLAYER_1, 2)
	wait(5)
	for u in extra do
		order_move(u, point(40, 40))
	end
end
"""
	var a := _sim(0xBEEF, src)
	var b := _sim(0xBEEF, src)
	if a == null or b == null:
		return
	for i in 60:
		a.step()
		b.step()
		if a.state_hash() != b.state_hash():
			_fail("determinism diverged at tick %d: %d vs %d" %
					[i, a.state_hash(), b.state_hash()])
			return
	# And a different seed path still produces *a* valid run (sanity, not equality).
	var c := _sim(0xBEEF, src)
	for i in 60:
		c.step()
	if c.state_hash() != a.state_hash():
		_fail("determinism: same seed re-run diverged from first run")


# --- A runaway loop must trip the op budget and return, never hang. ---
func _test_op_budget_no_hang() -> void:
	var src := """
on match_start
	local i: int = 0
	while true do
		i = i + 1
	end
end
"""
	var nat := _sim(1, src)
	if nat == null:
		return
	nat.step()  # must return (op budget kills the trigger), not spin forever
	# Reaching here without timing out is the assertion.
	if nat.get_tick() != 1:
		_fail("op budget: sim did not advance after a runaway trigger")

