extends SceneTree
## Headless checks for M4 Unit AI v1 (design_m4.md §9 / §16): stances change
## behavior deterministically — defensive holds/leashes and returns, reckless
## chases, skirmish kites at min distance, hold_position never moves to
## acquire, focus_fire concentrates — and PATROL swaps endpoints.
##
## Run on the host:
##   flatpak run org.godotengine.Godot --headless --path . \
##     -s res://tests/tactics_check.gd

var failures := 0


func _initialize() -> void:
	_test_reckless_chases()
	_test_balanced_holds()
	_test_hold_position()
	_test_defensive_returns()
	_test_skirmish_kites()
	_test_focus_fire()
	_test_patrol_swaps()

	if failures == 0:
		print("tactics_check: OK")
		quit(0)
	else:
		print("tactics_check: FAILED (%d)" % failures)
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
				"armor_classes": ["light"],
				"matrix": { "claw": { "light": "1.0" } },
				"leash_defensive": "5.0", "kite_min_distance": "4.0"
			}
		},
		"t.melee": {
			"kind": "unit",
			"sim": {
				"hp": 100, "damage": 5, "attack_class": "claw", "armor_class": "light",
				"radius": "0.4", "speed": "4.0", "attack_range": "0.5",
				"acquire_range": "20.0", "cooldown": "1.0", "sight": "25.0"
			}
		},
		"t.ranged": {
			"kind": "unit",
			"sim": {
				"hp": 100, "damage": 5, "attack_class": "claw", "armor_class": "light",
				"radius": "0.4", "speed": "4.0", "attack_range": "8.0",
				"acquire_range": "20.0", "cooldown": "1.0", "sight": "25.0"
			}
		},
		"t.dummy": {
			"kind": "unit",
			"sim": {
				"hp": 100000, "damage": 0, "armor_class": "light",
				"radius": "0.4", "speed": "0", "sight": "1.0"
			}
		},
	}


func _sim() -> Sim:
	var cat := CatalogCompiler.compile([_layer()])
	assert(cat.ok(), "tactics fixture catalog: %s" % [cat.errors])
	var map := MapData.blank(48, 48)
	map.players.append({"id": 1, "faction": "a", "start_alloy": 0, "start_flux": 0})
	map.players.append({"id": 2, "faction": "b", "start_alloy": 0, "start_flux": 0})
	map.rehash()
	return Sim.new(5, cat, map)


func _key(sim: Sim, id: String) -> int:
	return sim.catalog.key_of(id)


func _unit(sim: Sim, player: int, type_id: String, tx: int, ty: int) -> SimEntity:
	return sim.entities[sim.spawn_unit(player, tx * Fixed.ONE, ty * Fixed.ONE, _key(sim, type_id))]


func _set_tactic(sim: Sim, e: SimEntity, stance: int, flags: int = 0) -> void:
	var c := SimCommand.new(e.player, SimCommand.Kind.SET_TACTIC)
	c.targets = [e.id]
	c.params = {"stance": stance, "flags": flags}
	sim.schedule(c)


# --- tests --------------------------------------------------------------------


func _test_reckless_chases() -> void:
	var sim := _sim()
	var atk := _unit(sim, 1, "t.melee", 10, 10)
	var enemy := _unit(sim, 2, "t.dummy", 25, 10)  # within acquire (20), out of attack range
	_set_tactic(sim, atk, CatalogSchema.Stance.RECKLESS)
	var x0: int = atk.x
	for _t in 20:
		sim.step()
	_expect(atk.x > x0 + Fixed.ONE, "reckless unit chased toward the enemy (x %d -> %d)"
			% [x0, atk.x])
	_expect(enemy != null, "enemy exists")


func _test_balanced_holds() -> void:
	var sim := _sim()
	var atk := _unit(sim, 1, "t.melee", 10, 10)
	_unit(sim, 2, "t.dummy", 25, 10)
	# Default stance is balanced; it acquires and fires in range but does not
	# chase (M3 behavior).
	var x0: int = atk.x
	for _t in 20:
		sim.step()
	_expect(atk.x == x0, "balanced unit held position (did not chase)")


func _test_hold_position() -> void:
	var sim := _sim()
	var atk := _unit(sim, 1, "t.melee", 10, 10)
	_unit(sim, 2, "t.dummy", 25, 10)
	_set_tactic(sim, atk, CatalogSchema.Stance.RECKLESS,
			CatalogSchema.TacticFlag.HOLD_POSITION)
	var x0: int = atk.x
	for _t in 20:
		sim.step()
	_expect(atk.x == x0, "hold_position overrides reckless: never moves to acquire")


func _test_defensive_returns() -> void:
	var sim := _sim()
	var atk := _unit(sim, 1, "t.melee", 20, 20)
	_set_tactic(sim, atk, CatalogSchema.Stance.DEFENSIVE)  # anchors at (20,20)
	for _t in Sim.COMMAND_DELAY + 1:
		sim.step()
	_expect(atk.anchor_set, "defensive set an anchor")
	# Shove it far off the anchor, no enemy around: it walks back.
	atk.x = 35 * Fixed.ONE
	for _t in 120:
		sim.step()
	var dx: int = absi(atk.x - atk.anchor_x)
	_expect(dx <= Sim.ARRIVE_DIST, "defensive returned to its anchor (off by %d)" % dx)


func _test_skirmish_kites() -> void:
	var sim := _sim()
	var sk := _unit(sim, 1, "t.ranged", 20, 20)
	# Enemy well inside kite_min_distance (4 tiles).
	var enemy := _unit(sim, 2, "t.dummy", 22, 20)
	_set_tactic(sim, sk, CatalogSchema.Stance.SKIRMISH)
	var d0: int = absi(sk.x - enemy.x)
	for _t in 15:
		sim.step()
	var d1: int = absi(sk.x - enemy.x)
	_expect(d1 > d0, "skirmisher backed off from the too-close enemy (%d -> %d)" % [d0, d1])


func _test_focus_fire() -> void:
	var sim := _sim()
	var a := _unit(sim, 1, "t.ranged", 10, 10)
	var b := _unit(sim, 1, "t.ranged", 10, 11)
	# Two enemies in range of both.
	var e1 := _unit(sim, 2, "t.dummy", 14, 10)
	var e2 := _unit(sim, 2, "t.dummy", 14, 11)
	# Set the flag up front (the command's 3-tick delay would otherwise let
	# them lock separate targets before focus_fire applies).
	a.tactic_flags = CatalogSchema.TacticFlag.FOCUS_FIRE
	b.tactic_flags = CatalogSchema.TacticFlag.FOCUS_FIRE
	for _t in 12:
		sim.step()
	_expect(a.target_id != 0 and a.target_id == b.target_id,
			"focus_fire units concentrated on one target (a=%d b=%d)"
			% [a.target_id, b.target_id])
	_expect(e1 != null and e2 != null, "both enemies still exist")


func _test_patrol_swaps() -> void:
	var sim := _sim()
	var u := _unit(sim, 1, "t.melee", 10, 10)
	var c := SimCommand.new(1, SimCommand.Kind.PATROL)
	c.targets = [u.id]
	c.params = {"x": 30 * Fixed.ONE, "y": 10 * Fixed.ONE}
	sim.schedule(c)
	# Reaches B (x~30), then turns back toward A (x~10).
	var reached_b := false
	var returned := false
	for _t in 400:
		sim.step()
		if u.x >= 29 * Fixed.ONE:
			reached_b = true
		if reached_b and u.x <= 11 * Fixed.ONE:
			returned = true
			break
	_expect(reached_b, "patrol reached endpoint B")
	_expect(returned, "patrol swapped and returned toward endpoint A")
