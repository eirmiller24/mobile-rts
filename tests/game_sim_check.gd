extends SceneTree
## Verifies the GameSim adapter (native-backed view facade) presents reads
## identical to the frozen GDScript Sim: the rebuilt SimEntity / SimPlayer
## facades, the grid mirror, income, and should_render. This is the swap's
## correctness gate — the running game reads the game through GameSim.
##
## Skips (exit 0) if the native extension is not built.
## Run: godot --headless --path . -s res://tests/game_sim_check.gd

const SEED := 0xC0FFEE
const LOCAL := 1

var failures := 0


func _initialize() -> void:
	if not ClassDB.class_exists("NativeSim"):
		print("game_sim_check: SKIP (NativeSim not built)")
		quit(0)
		return

	var map := MapLoader.load_path("res://maps/dev_clash.json")
	MatchSetup.apply(map, MatchSetup.default_factions(map))
	if not map.ok():
		_fail("setup failed")
		_finish()
		return
	var gd := Sim.new(SEED, map.catalog, map)
	var game := GameSim.new()
	game.setup(SEED, map.catalog, map, LOCAL)

	for i in 400:
		gd.step()
		game.step()
		if not _compare(gd, game, i):
			break

	_finish()


func _finish() -> void:
	if failures == 0:
		print("game_sim_check: OK")
		quit(0)
	else:
		print("game_sim_check: FAILED (%d)" % failures)
		quit(1)


func _fail(msg: String) -> void:
	push_error(msg)
	failures += 1


func _compare(gd: Sim, game: GameSim, tick: int) -> bool:
	# grid mirror
	if game.grid.blocked_bytes() != gd.grid.blocked_bytes():
		_fail("tick %d: grid blocked mismatch" % tick); return false
	# income
	if str(game.income) != str(gd.income):
		_fail("tick %d: income mismatch" % tick); return false
	# players facade
	var gd_pids: Array = gd.players.keys(); gd_pids.sort()
	var game_pids: Array = game.players.keys(); game_pids.sort()
	if gd_pids != game_pids:
		_fail("tick %d: player ids mismatch" % tick); return false
	for pid in gd_pids:
		var gp: SimPlayer = gd.players[pid]
		var mp: SimPlayer = game.players[pid]
		if mp.eliminated_tick != gp.eliminated_tick or mp.auto_repair != gp.auto_repair \
				or mp.alloy != gp.alloy or mp.flux != gp.flux or mp.faction != gp.faction \
				or mp.had_main != gp.had_main:
			_fail("tick %d: player %d facade mismatch" % [tick, pid]); return false
	# entity facades
	var gd_ids: Array = gd._sorted_ids()
	var game_ids: Array = game._sorted_ids()
	if gd_ids != game_ids:
		_fail("tick %d: entity ids mismatch (%d vs %d)" % [tick, gd_ids.size(), game_ids.size()])
		return false
	for id in gd_ids:
		var e: SimEntity = gd.entities[id]
		var g: SimEntity = game.entities[id]
		if g.id != e.id or g.type_key != e.type_key or g.player != e.player or g.kind != e.kind \
				or g.x != e.x or g.y != e.y or g.radius != e.radius or g.hp != e.hp \
				or g.max_hp != e.max_hp or g.amount != e.amount or g.build_state != e.build_state \
				or g.build_ticks_left != e.build_ticks_left or g.foot_x != e.foot_x \
				or g.foot_y != e.foot_y or g.foot_w != e.foot_w or g.foot_h != e.foot_h \
				or g.resource_kind != e.resource_kind or g.nano_alloc != e.nano_alloc \
				or g.morphed != e.morphed or g.is_underground() != e.is_underground() \
				or g.is_unit() != e.is_unit() or g.is_resource() != e.is_resource() \
				or g.is_aerial() != e.is_aerial() or g.targetable != e.targetable:
			_fail("tick %d: entity %d facade mismatch" % [tick, id]); return false
		# should_render == own || resource || seen, for the local player
		var want: bool = e.player == LOCAL or e.is_resource() or gd.is_entity_visible(LOCAL, e)
		if game.should_render(g) != want:
			_fail("tick %d: should_render(%d) %s != %s" % [tick, id, game.should_render(g), want])
			return false
	return true
