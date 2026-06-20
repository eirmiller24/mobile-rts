extends SceneTree
## Tick-0 bit-exact parity between the native (C++) sim and the frozen GDScript
## reference (design_m5.md §2.4, §7 port_parity_check). Constructs both sims
## from the same seed + catalog + map and asserts state_hash() is identical
## before any step — exercising the full construction path (spawn, footprints,
## structure-complete, refinery linking, depot economy seeding, vision +
## discovered-resources) and the entire per-entity / per-player hash chain.
##
## The step()-driven systems are ported in a later milestone; this gate covers
## everything that exists at tick 0.
##
## Skips (exit 0) if the native extension is not built.
##
## Run:
##   godot --headless --path . -s res://tests/native_tick0_parity_check.gd

var failures := 0


func _initialize() -> void:
	if not ClassDB.class_exists("NativeSim"):
		print("native_tick0_parity_check: SKIP (NativeSim not built)")
		quit(0)
		return

	_check("res://maps/dev_arena.json", false)
	_check("res://maps/dev_clash.json", true)

	if failures == 0:
		print("native_tick0_parity_check: OK")
		quit(0)
	else:
		print("native_tick0_parity_check: FAILED (%d)" % failures)
		quit(1)


func _check(map_path: String, apply_setup: bool) -> void:
	for seed_value: int in [0xDEADBEEF, 1, 12345]:
		var map := MapLoader.load_path(map_path)
		if not map.ok():
			push_error("%s failed to load: %s" % [map_path, map.errors])
			failures += 1
			return
		if apply_setup:
			MatchSetup.apply(map, MatchSetup.default_factions(map))
			if not map.ok():
				push_error("%s match setup failed: %s" % [map_path, map.errors])
				failures += 1
				return

		var gd := Sim.new(seed_value, map.catalog, map)
		var nat: Object = ClassDB.instantiate("NativeSim")
		nat.construct(seed_value, map.catalog, map)

		var gd_h: int = gd.state_hash()
		var nat_h: int = nat.state_hash()
		if gd_h != nat_h:
			push_error("%s seed=%d tick-0 hash mismatch: gd=%d native=%d (entities=%d)" %
					[map_path, seed_value, gd_h, nat_h, gd.entities.size()])
			failures += 1
		else:
			print("  %s seed=%d: tick-0 hash %d (%d entities) OK" %
					[map_path, seed_value, gd_h, gd.entities.size()])
