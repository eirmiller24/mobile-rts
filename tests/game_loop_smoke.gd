extends SceneTree
## End-to-end swap check: the native-backed game (GameSim + bots, the real
## src/main.gd path) stays bit-identical to the GDScript-sim game (Sim + bots).
## Both run independent BotCommanders that read their own sim and schedule via
## sim.schedule(SimCommand) — so any error in the GameSim facade/adapter makes
## the bots diverge and the hashes split. Also exercises the per-tick view read
## (should_render over the entity facade) to catch crashes on the render path.
##
## Skips (exit 0) if the native extension is not built.
## Run: godot --headless --path . -s res://tests/game_loop_smoke.gd

const SEED := 0xC0FFEE
const LOCAL := 1
const TICKS := 700

var failures := 0


func _initialize() -> void:
	if not ClassDB.class_exists("NativeSim"):
		print("game_loop_smoke: SKIP (NativeSim not built)")
		quit(0)
		return

	var gd := _sim_gdscript()
	var game := _sim_native()
	if gd == null or game == null:
		_finish()
		return

	var gd_bots := _bots(gd)
	var game_bots := _bots(game)

	var rendered_any := false
	for i in TICKS:
		for b in gd_bots:
			b.tick()
		gd.step()
		for b in game_bots:
			b.tick()
		game.step()
		if gd.state_hash() != game.state_hash():
			push_error("game_loop_smoke: desync at tick %d (gd=%d game=%d)" %
					[i, gd.state_hash(), game.state_hash()])
			failures += 1
			break
		# Mimic the view's per-tick read over the native-backed facade.
		for id in game.entities:
			var e: SimEntity = game.entities[id]
			if game.should_render(e):
				rendered_any = true

	if not rendered_any:
		push_error("game_loop_smoke: nothing ever rendered (view path not exercised)")
		failures += 1

	_finish()


func _sim_gdscript() -> Sim:
	var map := MapLoader.load_path("res://maps/dev_clash.json")
	MatchSetup.apply(map, MatchSetup.default_factions(map))
	if not map.ok():
		_fail("gd setup failed"); return null
	return Sim.new(SEED, map.catalog, map)


func _sim_native() -> GameSim:
	var map := MapLoader.load_path("res://maps/dev_clash.json")
	MatchSetup.apply(map, MatchSetup.default_factions(map))
	if not map.ok():
		_fail("native setup failed"); return null
	var g := GameSim.new()
	g.setup(SEED, map.catalog, map, LOCAL)
	return g


func _bots(s) -> Array:
	var hive := BotCommander.new(s, 1, 0x5EED + 1)
	var rebels := BotCommander.new(s, 2, 0x5EED + 2)
	hive.scout_hints = [_main_pos(s, 2)]
	rebels.scout_hints = [_main_pos(s, 1)]
	return [hive, rebels]


func _main_pos(s, pid: int) -> Array:
	for id in s._sorted_ids():
		var e: SimEntity = s.entities[id]
		if e.player == pid and e.kind == SimEntity.Kind.STRUCTURE \
				and s.catalog.sim_of(e.type_key).get("is_main", false):
			return [e.x, e.y]
	return [0, 0]


func _fail(msg: String) -> void:
	push_error(msg)
	failures += 1


func _finish() -> void:
	if failures == 0:
		print("game_loop_smoke: OK (%d ticks, native-backed bots == GDScript bots)" % TICKS)
		quit(0)
	else:
		print("game_loop_smoke: FAILED (%d)" % failures)
		quit(1)
