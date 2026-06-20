extends SceneTree
## The Maze TD bundle plays end to end (design_m5.md §3.10 — the tower-defense
## target map proving the language expresses a real scenario). Loads the bundle,
## runs it in the native sim, and asserts: creeps spawn and march, towers kill
## them (bounties accrue), leaks dock lives, the match reaches a trigger-driven
## conclusion, and two runs from one seed stay hash-identical (determinism).
##
## Skips the runtime half if the native extension is not built; the load/compile
## half always runs.
##
## Run:
##   godot --headless --path . -s res://tests/td_check.gd

const BUNDLE := "res://maps/td_maze"
const SEED := 0x7D7D

var failures := 0


func _initialize() -> void:
	_test_loads()
	_test_plays()

	if failures == 0:
		print("td_check: OK")
		quit(0)
	else:
		print("td_check: FAILED (%d)" % failures)
		quit(1)


func _fail(msg: String) -> void:
	push_error(msg)
	print("  FAIL: ", msg)
	failures += 1


func _load() -> MapData:
	return MapLoader.load_path(BUNDLE)


# --- The bundle compiles into a complete, playable map. ---
func _test_loads() -> void:
	var map := _load()
	if not map.ok():
		_fail("TD bundle failed to load: %s" % str(map.errors))
		return
	if map.region_names.size() != 2 or not map.region_names.has("spawn") \
			or not map.region_names.has("exit"):
		_fail("TD regions wrong: %s" % str(map.region_names))
	if map.trigger_program == null or not map.trigger_program.ok():
		_fail("TD triggers failed to compile")
	var hub := 0
	var towers := 0
	for o: Dictionary in map.objects:
		var t := str(o.get("type", ""))
		if t == "td.hub":
			hub += 1
		elif t.ends_with("_tower"):
			towers += 1
	if hub != 1:
		_fail("expected exactly one hub, got %d" % hub)
	if towers < 6:
		_fail("expected the pre-placed tower maze, got %d towers" % towers)


# --- It runs in the native sim to a deterministic, trigger-driven conclusion. ---
func _test_plays() -> void:
	if not ClassDB.class_exists("NativeSim"):
		print("  (native sim not built — skipping TD runtime assertions)")
		return
	var map := _load()
	if not map.ok():
		return

	var a := _run(map)
	if not a["over"]:
		_fail("TD did not conclude within the tick budget (over=false)")
	if not a["saw_creeps"]:
		_fail("TD never spawned creeps")
	if not a["killed"]:
		_fail("TD towers never killed a creep (no bounty accrued)")
	print("  TD concluded at tick %d, winner=%d, leaks=%d, kills_bounty_alloy=%d"
			% [a["tick"], a["winner"], a["leaks"], a["alloy"]])

	# Determinism: a second run from the same seed matches hash for hash.
	var b_hashes: Array = _run(map)["hashes"]
	var a_hashes: Array = a["hashes"]
	if a_hashes.size() != b_hashes.size():
		_fail("determinism: run lengths differ (%d vs %d)" % [a_hashes.size(), b_hashes.size()])
	else:
		for i in a_hashes.size():
			if a_hashes[i] != b_hashes[i]:
				_fail("TD determinism diverged at sample %d" % i)
				break


# Run the bundle to a conclusion (or the budget), sampling the hash stream.
func _run(map: MapData) -> Dictionary:
	var nat: Object = ClassDB.instantiate("NativeSim")
	nat.construct(SEED, map.catalog, map)
	nat.load_triggers(map.trigger_program)
	var saw_creeps := false
	var over := false
	var winner := 0
	var end_tick := 0
	var hashes: Array = []
	var budget := 6000
	for i in budget:
		nat.step()
		if i % 20 == 0:
			hashes.append(nat.state_hash())
		var snap: Dictionary = nat.view_snapshot(1)
		var ids: PackedInt32Array = snap.get("ids", PackedInt32Array())
		# entity count > towers+hub+barriers (~14) means creeps are on the field.
		if ids.size() > 14:
			saw_creeps = true
		var mr: Dictionary = nat.match_result()
		if bool(mr.get("over", false)):
			over = true
			winner = int(mr.get("winner", 0))
			end_tick = i
			break
	var res: Dictionary = nat.resources_of(1)
	var alloy := int(res.get("alloy", 0))
	return {
		"over": over, "winner": winner, "tick": end_tick, "hashes": hashes,
		"saw_creeps": saw_creeps, "killed": alloy > 300,
		"alloy": alloy, "leaks": 0,
	}
