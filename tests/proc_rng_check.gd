extends SceneTree
## Headless checks for the WC3-style pseudo-random proc distribution:
## determinism, the stacking-bonus guarantee (base 25% + 25%/failure can
## never fail 4 times running), distribution sanity, and that bonus 0
## degrades to true constant chance. DRng is seeded, so the "statistical"
## numbers here are exact and the test can never flake.
##
## Run on the host:
##   flatpak run org.godotengine.Godot --headless --path . \
##     -s res://tests/proc_rng_check.gd

var failures := 0


func _initialize() -> void:
	_test_determinism()
	_test_stacking()
	_test_constant_chance()

	if failures == 0:
		print("proc_rng_check: OK")
		quit(0)
	else:
		print("proc_rng_check: FAILED (%d)" % failures)
		quit(1)


func _fail(msg: String) -> void:
	push_error(msg)
	failures += 1


func _test_determinism() -> void:
	var a := _roll_sequence(42, Fixed.ONE / 4, Fixed.ONE / 4, 200)
	var b := _roll_sequence(42, Fixed.ONE / 4, Fixed.ONE / 4, 200)
	var c := _roll_sequence(43, Fixed.ONE / 4, Fixed.ONE / 4, 200)
	if a != b:
		_fail("same seed produced different proc sequences")
	if a == c:
		_fail("different seeds produced identical proc sequences")


func _test_stacking() -> void:
	if ProcRng.max_failures(Fixed.ONE / 4, Fixed.ONE / 4) != 3:
		_fail("max_failures(25%%, 25%%) should be 3")

	var rng := DRng.new(7)
	var stacks := {}
	var successes := 0
	var run := 0
	var worst_run := 0
	var n := 10000
	for i in n:
		if ProcRng.roll(rng, stacks, "crit", Fixed.ONE / 4, Fixed.ONE / 4):
			successes += 1
			run = 0
		else:
			run += 1
			worst_run = maxi(worst_run, run)
	if worst_run > 3:
		_fail("stacking proc failed %d times in a row; 3 is the maximum" % worst_run)
	# Expected success rate for base 1/4 + bonus 1/4 is ~45%.
	if successes < n * 40 / 100 or successes > n * 50 / 100:
		_fail("stacking proc rate off: %d/%d successes" % [successes, n])


func _test_constant_chance() -> void:
	if ProcRng.max_failures(Fixed.ONE / 4, 0) != -1:
		_fail("bonus 0 should never guarantee a success")

	var rng := DRng.new(7)
	var stacks := {}
	var successes := 0
	var run := 0
	var worst_run := 0
	var n := 20000
	for i in n:
		if ProcRng.roll(rng, stacks, "crit", Fixed.ONE / 4, 0):
			successes += 1
			run = 0
		else:
			run += 1
			worst_run = maxi(worst_run, run)
	if worst_run <= 3:
		_fail("constant chance never streaked past 3 failures; suspicious")
	if successes < n * 22 / 100 or successes > n * 28 / 100:
		_fail("constant chance rate off: %d/%d successes" % [successes, n])


func _roll_sequence(seed_value: int, base: int, bonus: int, n: int) -> Array[bool]:
	var rng := DRng.new(seed_value)
	var stacks := {}
	var result: Array[bool] = []
	for i in n:
		result.append(ProcRng.roll(rng, stacks, "p", base, bonus))
	return result
