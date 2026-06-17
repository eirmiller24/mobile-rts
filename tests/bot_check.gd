extends SceneTree
## Headless checks for the M4 scripted bot (design_m4.md §8 / §16): a
## BotCommander with a fixed seed beats a do-nothing opponent by a knowable
## tick, every command it emits passes sim validation, and the *recorded
## command stream* re-run through a fresh sim reproduces the identical hash
## stream (proving "a replay reproduces the bot from its commands").
##
## Run on the host:
##   flatpak run org.godotengine.Godot --headless --path . \
##     -s res://tests/bot_check.gd

var failures := 0


func _initialize() -> void:
	_test_bot_wins_and_replays()

	if failures == 0:
		print("bot_check: OK")
		quit(0)
	else:
		print("bot_check: FAILED (%d)" % failures)
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
				"armor_classes": ["light", "structure"],
				"matrix": { "claw": { "light": "1.0", "structure": "1.0" } },
				"alloy_rate": "1.0"
			}
		},
		"b.aura": {
			"kind": "ability",
			"sim": {
				"ability_kind": "aura", "radius": "12.0",
				"affects": "own_structures", "flags": ["territory"],
				"modifiers": { "hp_regen": "0", "damage_taken": "1.0" }
			}
		},
		"b.fort": {
			"kind": "structure",
			"sim": {
				"hp": 1000, "foot_w": 4, "foot_h": 4, "armor_class": "structure",
				"build_time": "1.0", "sight": "16.0", "is_main": true,
				"bandwidth_provided": 30, "nano_pool": 30, "default_allocation": "alloy",
				"abilities": ["b.aura"], "trains": ["b.soldier"]
			}
		},
		"b.soldier": {
			"kind": "unit",
			"sim": {
				"hp": 70, "damage": 12, "attack_class": "claw", "armor_class": "light",
				"radius": "0.4", "speed": "5.0", "attack_range": "0.6",
				"acquire_range": "8.0", "cooldown": "1.0", "sight": "10.0",
				"bandwidth": 1, "cost_alloy": 10, "train_time": "1.5"
			}
		},
		"b.target": {
			"kind": "structure",
			"sim": {
				"hp": 500, "foot_w": 4, "foot_h": 4, "armor_class": "structure",
				"build_time": "1.0", "sight": "10.0", "is_main": true
			}
		},
		"b.deposit": {
			"kind": "resource",
			"sim": { "resource": "alloy", "amount": 1000000, "throughput": "100.0",
				"foot_w": 2, "foot_h": 2 }
		},
	}


func _make_sim() -> Sim:
	var cat := CatalogCompiler.compile([_layer()])
	assert(cat.ok(), "bot fixture catalog: %s" % [cat.errors])
	var map := MapData.blank(40, 40)
	map.players.append({"id": 1, "faction": "bot", "start_alloy": 50, "start_flux": 0})
	map.players.append({"id": 2, "faction": "dummy", "start_alloy": 0, "start_flux": 0})
	map.rehash()
	var sim := Sim.new(0xB0, cat, map)
	sim.spawn_structure(1, 8, 8, cat.key_of("b.fort"))
	sim.spawn_resource(16, 10, cat.key_of("b.deposit"))
	sim.spawn_structure(2, 64, 64, cat.key_of("b.target"))
	return sim


func _enemy_main_pos(sim: Sim) -> Array:
	for id in sim.entities:
		var e: SimEntity = sim.entities[id]
		if e.player == 2 and e.kind == SimEntity.Kind.STRUCTURE:
			return [e.x, e.y]
	return [0, 0]


func _test_bot_wins_and_replays() -> void:
	var sim := _make_sim()
	var bot := BotCommander.new(sim, 1, 1234)
	bot.scout_hints = [_enemy_main_pos(sim)]

	var win_tick := -1
	for _t in 4000:
		bot.tick()
		sim.step()
		_replay_hashes.append(sim.state_hash())
		if sim.match_result()["over"]:
			win_tick = sim.tick
			break

	var res := sim.match_result()
	_expect(res["over"], "the bot finished the match")
	_expect(res["winner"] == 1, "the bot (player 1) won")
	_expect(win_tick != -1 and win_tick < 4000, "bot won within the tick budget (at %d)" % win_tick)
	_expect(not bot.issued.is_empty(), "the bot issued commands")

	# Every emitted command must pass sim validation: re-running the recorded
	# stream through a fresh sim must reproduce the *identical* hash stream.
	var sim2 := _make_sim()
	for rec: Dictionary in bot.issued:
		sim2.schedule(rec["cmd"], rec["at"])
	var ok := true
	for t in win_tick:
		sim2.step()
		if sim2.state_hash() != _replay_hashes[t]:
			ok = false
			break
	_expect(ok, "replaying the recorded bot stream reproduced the hash stream")
	_expect(sim2.match_result()["over"] and sim2.match_result()["winner"] == 1,
			"the replay reaches the same result")


# Captured during the live run for the replay comparison.
var _replay_hashes: Array[int] = []
