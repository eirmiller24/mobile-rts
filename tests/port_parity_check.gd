extends SceneTree
## Per-tick bit-exact parity: the C++ sim vs the frozen GDScript oracle on
## identical seed + command streams (design_m5.md §2.4, §7 port_parity_check).
## Asserts state_hash() matches every tick across scenarios that exercise the
## full M4 system set: worker + nano economy, production, harvest, structures,
## vision, movement, collision, combat, crits, abilities, walls.
##
## Commands are scheduled identically on both sims (_sched). The harness never
## consumes either sim's rng — randomized orders draw from a separate local DRng
## so the two sims' hashed rng state stays in lockstep.
##
## Skips (exit 0) if the native extension is not built.
## Run: godot --headless --path . -s res://tests/port_parity_check.gd

const SEED := 0xDEADBEEF
const MAP_TILES := 32

var failures := 0


func _initialize() -> void:
	if not ClassDB.class_exists("NativeSim"):
		print("port_parity_check: SKIP (NativeSim not built)")
		quit(0)
		return

	_economy_scenario()
	_combat_scenario()
	_m3_scenario()
	_bot_scenario()

	if failures == 0:
		print("port_parity_check: OK")
		quit(0)
	else:
		print("port_parity_check: FAILED (%d)" % failures)
		quit(1)


func _native() -> Object:
	return ClassDB.instantiate("NativeSim")


func _sched(gd: Sim, nat: Object, player: int, kind: int, targets: Array,
		params: Dictionary, seq: int, at: int = -1) -> void:
	var cmd := SimCommand.new(player, kind)
	cmd.targets.assign(targets)
	cmd.params = params
	cmd.seq = seq
	gd.schedule(cmd, at)
	nat.schedule(player, kind, PackedInt32Array(targets), params, seq, at)


func _step_compare(label: String, gd: Sim, nat: Object, i: int) -> bool:
	gd.step()
	nat.step()
	var gh: int = gd.state_hash()
	var nh: int = nat.state_hash()
	if gh != nh:
		push_error("%s: desync at tick %d (gd=%d native=%d, entities gd=%d)" %
				[label, i, gh, nh, gd.entities.size()])
		failures += 1
		return false
	return true


func _run_compare(label: String, gd: Sim, nat: Object, ticks: int) -> bool:
	for i in ticks:
		if not _step_compare(label, gd, nat, gd.tick):
			return false
	print("  %s: OK (%d ticks, final hash %d)" % [label, ticks, gd.state_hash()])
	return true


# --- Scenario 1: both economies auto-run, no player input -------------------
func _economy_scenario() -> void:
	var map := MapLoader.load_path("res://maps/dev_clash.json")
	MatchSetup.apply(map, MatchSetup.default_factions(map))
	if not map.ok():
		push_error("economy: setup failed: %s" % [map.errors])
		failures += 1
		return
	var gd := Sim.new(SEED, map.catalog, map)
	var nat := _native()
	nat.construct(SEED, map.catalog, map)
	if gd.state_hash() != nat.state_hash():
		push_error("economy: tick-0 mismatch")
		failures += 1
		return
	_run_compare("economy(dev_clash, no commands)", gd, nat, 600)


# --- Scenario 2: M2 combat (walled gap, crits, RNG moves) -------------------
func _combat_scenario() -> void:
	var cat := TestSupport.catalog()
	var map := MapData.blank(MAP_TILES, MAP_TILES)
	for pid in [0, 1, 2]:
		map.players.append({"id": pid, "faction": "test",
				"start_alloy": 100000, "start_flux": 100000})
	var critter := cat.key_of(TestSupport.CRITTER)
	var grunt := cat.key_of(TestSupport.GRUNT)
	var wall_key := cat.key_of(TestSupport.WALL)
	# Author all objects into the map so both sims spawn them identically at
	# construction; commands then only move/attack.
	var squad_a: Array[int] = []
	var squad_b: Array[int] = []
	var nid := 1
	for i in 6:
		map.objects.append({"type_key": critter, "type": TestSupport.CRITTER, "player": 0,
				"x": Fixed.from_int(6 + (i % 3) * 2), "y": Fixed.from_int(14 + (i / 3) * 2)})
		squad_a.append(nid); nid += 1
		map.objects.append({"type_key": grunt, "type": TestSupport.GRUNT, "player": 1,
				"x": Fixed.from_int(24 + (i % 3) * 2), "y": Fixed.from_int(14 + (i / 3) * 2)})
		squad_b.append(nid); nid += 1
	for cy in range(20, 45):
		if cy >= 30 and cy <= 33:
			continue
		map.objects.append({"type_key": wall_key, "type": TestSupport.WALL, "player": 2,
				"cx": 32, "cy": cy, "completed": true})
		nid += 1
	map.rehash()

	var gd := Sim.new(SEED, cat, map)
	var nat := _native()
	nat.construct(SEED, cat, map)
	if gd.state_hash() != nat.state_hash():
		push_error("combat: tick-0 mismatch")
		failures += 1
		return

	var seq := 0
	_sched(gd, nat, 0, SimCommand.Kind.ATTACK_MOVE, squad_a,
			{"x": Fixed.from_int(26), "y": Fixed.from_int(16)}, seq, 5); seq += 1
	_sched(gd, nat, 1, SimCommand.Kind.ATTACK_MOVE, squad_b,
			{"x": Fixed.from_int(6), "y": Fixed.from_int(16)}, seq, 5); seq += 1

	var hrng := DRng.new(0x5151)  # harness rng — never touches either sim's rng
	for i in 400:
		if i % 50 == 25:
			var target := squad_a[hrng.randi_range(0, 5)]
			var mx := Fixed.from_int(hrng.randi_range(2, MAP_TILES - 2))
			var my := Fixed.from_int(hrng.randi_range(2, MAP_TILES - 2))
			_sched(gd, nat, 0, SimCommand.Kind.MOVE, [target], {"x": mx, "y": my}, 1000 + i, -1)
		if not _step_compare("combat", gd, nat, i):
			return
	print("  combat(walled gap, crits): OK (400 ticks, final hash %d)" % gd.state_hash())


# --- Scenario 3: M3 scripted Hive (economy, builds, train, abilities) -------
func _m3_scenario() -> void:
	var map := MapLoader.load_path("res://maps/dev_arena.json")
	if not map.ok():
		push_error("m3: load failed")
		failures += 1
		return
	var gd := Sim.new(SEED, map.catalog, map)
	var nat := _native()
	nat.construct(SEED, map.catalog, map)
	var cat := gd.catalog
	var sh := _find_type(gd, "hive.stronghold")
	if sh == null:
		push_error("m3: no stronghold")
		failures += 1
		return
	var seq := 0
	# Pre-spawn a lancer + carapace via DEBUG_SPAWN at tick 0 (identical id
	# allocation on both sims) so the ability runtime is exercised.
	_sched(gd, nat, 1, SimCommand.Kind.DEBUG_SPAWN, [],
			{"x": Fixed.from_int(30), "y": Fixed.from_int(30), "type": cat.key_of("hive.lancer")}, seq, 0); seq += 1
	_sched(gd, nat, 1, SimCommand.Kind.DEBUG_SPAWN, [],
			{"x": Fixed.from_int(31), "y": Fixed.from_int(31), "type": cat.key_of("hive.carapace")}, seq, 0); seq += 1
	_sched(gd, nat, 1, SimCommand.Kind.ALLOCATE_ECONOMY, [sh.id],
			{"alloy": 40, "flux": 0, "assist": 10}, seq, 5); seq += 1
	_sched(gd, nat, 1, SimCommand.Kind.BUILD, [sh.id],
			{"type": cat.key_of("hive.relay"), "cx": 30, "cy": 20}, seq, 8); seq += 1
	_sched(gd, nat, 1, SimCommand.Kind.BUILD, [sh.id],
			{"type": cat.key_of("hive.relay"), "cx": 60, "cy": 70}, seq, 10); seq += 1
	_sched(gd, nat, 1, SimCommand.Kind.BUILD, [sh.id],
			{"type": cat.key_of("hive.siphon"), "cx": 36, "cy": 36}, seq, 12); seq += 1
	_sched(gd, nat, 1, SimCommand.Kind.SET_RALLY, [sh.id],
			{"x": Fixed.from_int(30), "y": Fixed.from_int(30)}, seq, 14); seq += 1
	_sched(gd, nat, 1, SimCommand.Kind.TRAIN, [sh.id], {"type": cat.key_of("hive.mite")}, seq, 20); seq += 1

	if not _run_compare("m3 phase1", gd, nat, 60):
		return
	var lan := _find_type(gd, "hive.lancer")
	var car := _find_type(gd, "hive.carapace")
	if lan != null:
		_sched(gd, nat, 1, SimCommand.Kind.ABILITY, [lan.id],
				{"ability": cat.key_of("hive.burrow"), "x": Fixed.from_int(36), "y": Fixed.from_int(36)},
				seq, gd.tick + 3); seq += 1
	if car != null:
		_sched(gd, nat, 1, SimCommand.Kind.ABILITY, [car.id],
				{"ability": cat.key_of("hive.root")}, seq, gd.tick + 4); seq += 1
	if not _run_compare("m3 phase2", gd, nat, 400):
		return
	var army: Array[int] = []
	for id in gd._sorted_ids():
		var e: SimEntity = gd.entities[id]
		if e.player == 1 and e.is_unit() and e.hp > 0:
			army.append(id)
	_sched(gd, nat, 1, SimCommand.Kind.ATTACK_MOVE, army,
			{"x": Fixed.from_int(41), "y": Fixed.from_int(41)}, seq, gd.tick + 3); seq += 1
	_run_compare("m3 phase3", gd, nat, 340)


# --- Scenario 4: the canonical M4 bot match (both AIs to elimination) --------
# The bots schedule commands to the GDScript sim; every newly-queued command is
# mirrored to the native sim before stepping. The bot's own rng is separate from
# the sim's, so it never perturbs hashed sim state.
func _bot_scenario() -> void:
	var map := MapLoader.load_path("res://maps/dev_clash.json")
	MatchSetup.apply(map, MatchSetup.default_factions(map))
	if not map.ok():
		push_error("bot: setup failed")
		failures += 1
		return
	var gd := Sim.new(SEED, map.catalog, map)
	var nat := _native()
	nat.construct(SEED, map.catalog, map)
	var hive := BotCommander.new(gd, 1, 0x5EED + 1)
	var rebels := BotCommander.new(gd, 2, 0x5EED + 2)
	hive.scout_hints = [_main_pos(gd, 2)]
	rebels.scout_hints = [_main_pos(gd, 1)]

	var captured := {}  # at_tick -> count already mirrored to native
	for i in 1000:
		hive.tick()
		rebels.tick()
		for at: int in gd._command_queue:
			var arr: Array = gd._command_queue[at]
			var start: int = captured.get(at, 0)
			for j in range(start, arr.size()):
				var c: SimCommand = arr[j]
				nat.schedule(c.player_id, c.kind, PackedInt32Array(c.targets), c.params, c.seq, at)
			captured[at] = arr.size()
		gd.step()
		nat.step()
		var gh: int = gd.state_hash()
		var nh: int = nat.state_hash()
		if gh != nh:
			push_error("bot: desync at tick %d (gd=%d native=%d, entities gd=%d)" %
					[i, gh, nh, gd.entities.size()])
			failures += 1
			return
	print("  bot(dev_clash, 2 AIs): OK (1000 ticks, final hash %d)" % gd.state_hash())


func _main_pos(sim: Sim, pid: int) -> Array:
	for id in sim._sorted_ids():
		var e: SimEntity = sim.entities[id]
		if e.player == pid and e.kind == SimEntity.Kind.STRUCTURE \
				and sim.catalog.sim_of(e.type_key).get("is_main", false):
			return [e.x, e.y]
	return [0, 0]


func _find_type(sim: Sim, type_id: String) -> SimEntity:
	for id in sim._sorted_ids():
		var e: SimEntity = sim.entities[id]
		if sim.catalog.id_of(e.type_key) == type_id:
			return e
	return null
