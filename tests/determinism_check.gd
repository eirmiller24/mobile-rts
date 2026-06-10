extends SceneTree
## Headless determinism check: run two sims with the same seed and command
## stream and assert their state hashes match at every step, then run a
## third with a different seed and assert it diverges.
##
## Run on the host (Godot is not installed in the devcontainer):
##   flatpak run org.godotengine.Godot --headless --path . \
##     -s res://tests/determinism_check.gd

const SEED := 0xDEADBEEF
const TICKS := 200


func _initialize() -> void:
	var a := _run(SEED)
	var b := _run(SEED)
	var c := _run(SEED + 1)

	var failures := 0
	for i in TICKS:
		if a[i] != b[i]:
			push_error("desync at tick %d: %d != %d" % [i, a[i], b[i]])
			failures += 1
	if a == c:
		push_error("different seeds produced identical state histories")
		failures += 1

	if failures == 0:
		print("determinism_check: OK (%d ticks)" % TICKS)
		quit(0)
	else:
		print("determinism_check: FAILED")
		quit(1)


func _run(seed_value: int) -> Array[int]:
	var sim := Sim.new(seed_value)
	var hashes: Array[int] = []
	for i in TICKS:
		if i % 10 == 0:
			var cmd := SimCommand.new(1, SimCommand.Kind.DEBUG_SPAWN)
			cmd.seq = i
			cmd.params = {
				"x": Fixed.from_int(sim.rng.randi_range(0, 63)),
				"y": Fixed.from_int(sim.rng.randi_range(0, 63)),
			}
			sim.schedule(cmd)
		sim.step()
		hashes.append(sim.state_hash())
	return hashes
