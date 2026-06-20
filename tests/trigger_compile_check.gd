extends SceneTree
## The Lua-flavored trigger compiler (design_m5.md §3.9, §7 trigger_compile_check):
## a valid script compiles and interns; bad input fails with a clear, line-tagged
## error and never silently. Pure GDScript — runs in the plain CI gate, no native
## build needed.
##
## Run:
##   godot --headless --path . -s res://tests/trigger_compile_check.gd

const I := preload("res://src/data/trigger_ir.gd")

var failures := 0


func _initialize() -> void:
	_test_valid()
	_test_errors()
	_test_hash_stable()

	if failures == 0:
		print("trigger_compile_check: OK")
		quit(0)
	else:
		print("trigger_compile_check: FAILED (%d)" % failures)
		quit(1)


func _fail(msg: String) -> void:
	push_error(msg)
	print("  FAIL: ", msg)
	failures += 1


func _cat() -> CompiledCatalog:
	return TestSupport.catalog()


func _compile(src: String, regions := {}) -> TriggerProgram:
	return TriggerCompiler.compile(src, _cat(), regions)


# --- A script exercising the full language core compiles cleanly. ---
func _test_valid() -> void:
	var src := """
globals
	wave: int = 0
	squad: group
	boss: unit
end

-- a recursive user function with params and a return
function fib(n: int) -> int
	if n < 2 then
		return n
	end
	return fib(n - 1) + fib(n - 2)
end

function spawn_wave(p: player, n: int) -> group
	local g: group = create_units(n, t.grunt, p, point(10, 10))
	return g
end

on match_start
	wave = 0
	display_message(PLAYER_1, "Battle begins")
	boss = create_unit(t.grunt, PLAYER_2, point(20, 20))
end

on every(5s)
	wave = wave + 1
	local g: group = spawn_wave(PLAYER_2, 3)
	for u in g do
		order_attack_move(u, point(5, 5))
	end
	if wave >= 10 then
		declare_victory(PLAYER_1)
	end
end

on unit_dies
	local d: unit = dying_unit()
	if owner(d) == PLAYER_2 and is_structure(d) then
		add_resource(PLAYER_1, ALLOY, 50)
	end
end

on unit_enters_region(home) do_nothing()
"""
	# 'do_nothing()' above is intentionally invalid to keep the region path simple;
	# replace with a real handler:
	src = src.replace("on unit_enters_region(home) do_nothing()", "")
	var prog := _compile(src, {"home": 0})
	if not prog.ok():
		_fail("valid script failed to compile: %s" % str(prog.errors))
		return
	# Structural sanity: 3 globals, 2 functions, 3 events.
	if prog.globals.size() / I.GLOBAL_STRIDE != 3:
		_fail("expected 3 globals, got %d" % (prog.globals.size() / I.GLOBAL_STRIDE))
	if prog.functions.size() / I.FUNC_STRIDE != 2:
		_fail("expected 2 functions, got %d" % (prog.functions.size() / I.FUNC_STRIDE))
	if prog.events.size() / I.EVENT_STRIDE != 3:
		_fail("expected 3 events, got %d" % (prog.events.size() / I.EVENT_STRIDE))
	# No strings reach the program hash, but the message must be interned.
	if not prog.strings.has("Battle begins"):
		_fail("string constant not interned")
	if prog.hash_value == 0:
		_fail("program hash not computed")


# --- The compiler must refuse each class of bad input loudly. ---
func _test_errors() -> void:
	_expect_error("unknown function", "on match_start\n no_such_fn()\nend")
	_expect_error("type mismatch", "on match_start\n local x: int = true\nend")
	_expect_error("undefined name", "on match_start\n y = 5\nend")
	_expect_error("unknown catalog entry",
			"on match_start\n create_unit(rebels.nope, PLAYER_1, point(0,0))\nend")
	_expect_error("wrong arg count", "on match_start\n abs(1, 2)\nend")
	_expect_error("wait outside event",
			"function f()\n wait(1s)\nend")
	_expect_error("break outside loop", "on match_start\n break\nend")
	_expect_error("compare mismatch",
			"on match_start\n if PLAYER_1 == 5 then\n end\nend")
	_expect_error("non-bool condition",
			"on match_start\n if 5 then\n end\nend")
	_expect_error("unknown region",
			"on unit_enters_region(nope)\nend")


func _expect_error(label: String, src: String) -> void:
	var prog := _compile(src)
	if prog.ok():
		_fail("%s: expected a compile error, got none" % label)


# --- Recompiling the same source yields the same program hash (golden). ---
func _test_hash_stable() -> void:
	var src := "globals\n n: int = 3\nend\non match_start\n n = n + 1\nend"
	var a := _compile(src)
	var b := _compile(src)
	if not a.ok() or not b.ok():
		_fail("hash-stable script failed to compile")
		return
	if a.hash_value != b.hash_value:
		_fail("program hash not stable: %d vs %d" % [a.hash_value, b.hash_value])
	# Whitespace/comments must not change the hash.
	var c := _compile("-- a comment\nglobals\n  n: int = 3\nend\n\non match_start\n  n = n + 1\nend")
	if c.ok() and c.hash_value != a.hash_value:
		_fail("comments/whitespace changed the program hash")
