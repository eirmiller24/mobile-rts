extends SceneTree
## Bit-exact parity check for the native (C++ GDExtension) sim substrate
## against the frozen GDScript reference (design_m5.md §2.4, §7
## port_parity_check at the substrate level). Verifies Fixed, DRng, ProcRng,
## SimHash, and SimGrid produce identical results across the boundary.
##
## Skips cleanly (exit 0) if the native extension is not built, so the pure
## GDScript CI gate is unaffected; the native CI job builds first, then this
## test becomes a hard gate.
##
## Run:
##   godot --headless --path . -s res://tests/native_substrate_check.gd

var failures := 0


func _initialize() -> void:
	if not ClassDB.class_exists("NativeSim"):
		print("native_substrate_check: SKIP (NativeSim not built)")
		quit(0)
		return
	var n: Object = ClassDB.instantiate("NativeSim")

	_test_fixed(n)
	_test_drng(n)
	_test_proc(n)
	_test_simhash(n)
	_test_grid(n)

	if failures == 0:
		print("native_substrate_check: OK")
		quit(0)
	else:
		print("native_substrate_check: FAILED (%d)" % failures)
		quit(1)


func _fail(msg: String) -> void:
	push_error(msg)
	print("  FAIL: ", msg)
	failures += 1


func _test_fixed(n: Object) -> void:
	var vals := [0, 1, -1, 2, -2, 7, 256, -256, 65535, 65536, 65537,
			100000, -100000, 1 << 20, -(1 << 20), 3 * Fixed.ONE, Fixed.HALF,
			-(5 * Fixed.ONE) - 12345]
	for a: int in vals:
		if n.fixed_from_int(a) != Fixed.from_int(a):
			_fail("from_int(%d)" % a)
		if n.fixed_to_int(a) != Fixed.to_int(a):
			_fail("to_int(%d)" % a)
		if n.fixed_floor(a) != Fixed.floor(a):
			_fail("floor(%d): native %d ref %d" % [a, n.fixed_floor(a), Fixed.floor(a)])
		if n.fixed_round(a) != Fixed.round(a):
			_fail("round(%d)" % a)
		if a >= 0 and n.fixed_sqrt(a) != Fixed.sqrt(a):
			_fail("sqrt(%d): native %d ref %d" % [a, n.fixed_sqrt(a), Fixed.sqrt(a)])
	for a: int in vals:
		for b: int in vals:
			if n.fixed_mul(a, b) != Fixed.mul(a, b):
				_fail("mul(%d,%d): native %d ref %d" %
						[a, b, n.fixed_mul(a, b), Fixed.mul(a, b)])
			if b != 0 and n.fixed_div(a, b) != Fixed.div(a, b):
				_fail("div(%d,%d): native %d ref %d" %
						[a, b, n.fixed_div(a, b), Fixed.div(a, b)])


func _test_drng(n: Object) -> void:
	for seed_value: int in [0, 1, 42, 7, 1337, 0xABCDEF, 2147483647]:
		var native: PackedInt64Array = n.drng_stream(seed_value, 256)
		var rng := DRng.new(seed_value)
		for i in 256:
			if native[i] != rng.next():
				_fail("drng next() seed=%d i=%d" % [seed_value, i])
				break
		# randi_range
		var nr: PackedInt64Array = n.drng_randi_range(seed_value, 0, 99, 128)
		var rng2 := DRng.new(seed_value)
		for i in 128:
			if nr[i] != rng2.randi_range(0, 99):
				_fail("drng randi_range seed=%d i=%d" % [seed_value, i])
				break
		# rand_fixed
		var nf: PackedInt64Array = n.drng_rand_fixed(seed_value, 128)
		var rng3 := DRng.new(seed_value)
		for i in 128:
			if nf[i] != rng3.rand_fixed():
				_fail("drng rand_fixed seed=%d i=%d" % [seed_value, i])
				break


func _test_proc(n: Object) -> void:
	var cases := [
		[Fixed.ONE / 4, Fixed.ONE / 4],
		[Fixed.ONE / 4, 0],
		[Fixed.ONE / 10, Fixed.ONE / 20],
		[Fixed.ONE / 2, Fixed.ONE / 3],
	]
	for seed_value: int in [7, 42, 99]:
		for c: Array in cases:
			var base: int = c[0]
			var bonus: int = c[1]
			var native: PackedInt32Array = n.proc_rolls(seed_value, base, bonus, 500)
			var rng := DRng.new(seed_value)
			var stacks := {}
			for i in 500:
				var ref: int = 1 if ProcRng.roll(rng, stacks, "crit", base, bonus) else 0
				if native[i] != ref:
					_fail("proc seed=%d base=%d bonus=%d i=%d" %
							[seed_value, base, bonus, i])
					break


func _test_simhash(n: Object) -> void:
	for s: String in ["", "hive", "rebels", "crit", "test", "core.classes",
			"t.grunt", "a longer string with spaces", "üñîçødé"]:
		if n.simhash_string(s) != SimHash.fnv_string(s):
			_fail("simhash_string(%s): native %d ref %d" %
					[s, n.simhash_string(s), SimHash.fnv_string(s)])


func _test_grid(n: Object) -> void:
	# A few block patterns; compare grid hash and nearest_free_cell.
	var patterns := [
		PackedInt32Array(),
		PackedInt32Array([2, 2, 3, 3]),
		PackedInt32Array([0, 0, 1, 1, 5, 5, 4, 2, 10, 10, 1, 1]),
	]
	for blocks: PackedInt32Array in patterns:
		var ref := SimGrid.new(16, 16)
		for i in range(0, blocks.size() - 3, 4):
			ref.block_rect(blocks[i], blocks[i + 1], blocks[i + 2], blocks[i + 3])
		var nh: int = n.grid_hash(16, 16, blocks)
		var rh: int = ref.hash_into(0)
		if nh != rh:
			_fail("grid_hash native %d ref %d" % [nh, rh])
		for probe: Array in [[3, 3], [0, 0], [5, 6], [15, 15], [8, 8]]:
			var nf: int = n.grid_nearest_free(16, 16, blocks, probe[0], probe[1])
			var rf: int = ref.nearest_free_cell(probe[0], probe[1])
			if nf != rf:
				_fail("grid_nearest_free(%d,%d) native %d ref %d" %
						[probe[0], probe[1], nf, rf])
