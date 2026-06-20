extends SceneTree
## Parity for the native batch view-read API (design_m5.md §2.3): the packed
## arrays NativeSim returns must match, field for field, what the view reads off
## the GDScript Sim per entity. Covers view_snapshot, vision_of, resources_of,
## bandwidth_of, match_result, and is_entity_visible across a running match.
##
## Skips (exit 0) if the native extension is not built.
## Run: godot --headless --path . -s res://tests/native_view_api_check.gd

const SEED := 0xDEADBEEF

var failures := 0


func _initialize() -> void:
	if not ClassDB.class_exists("NativeSim"):
		print("native_view_api_check: SKIP (NativeSim not built)")
		quit(0)
		return

	var map := MapLoader.load_path("res://maps/dev_clash.json")
	MatchSetup.apply(map, MatchSetup.default_factions(map))
	if not map.ok():
		push_error("view_api: setup failed")
		failures += 1
		_finish()
		return
	var gd := Sim.new(SEED, map.catalog, map)
	var nat: Object = ClassDB.instantiate("NativeSim")
	nat.construct(SEED, map.catalog, map)

	for i in 400:
		gd.step()
		nat.step()
		if not _compare(gd, nat, i):
			break
		if i % 20 == 0 and not _compare_queries(gd, nat, i):
			break

	_finish()


func _finish() -> void:
	if failures == 0:
		print("native_view_api_check: OK")
		quit(0)
	else:
		print("native_view_api_check: FAILED (%d)" % failures)
		quit(1)


func _fail(msg: String) -> void:
	push_error(msg)
	failures += 1


func _compare(gd: Sim, nat: Object, tick: int) -> bool:
	# entity snapshot, for each viewer
	for viewer in [0, 1, 2]:
		var snap: Dictionary = nat.view_snapshot(viewer)
		var ids: PackedInt32Array = snap["ids"]
		var gd_ids: Array = gd._sorted_ids()
		if ids.size() != gd_ids.size():
			_fail("tick %d viewer %d: snapshot size %d != gd %d" %
					[tick, viewer, ids.size(), gd_ids.size()])
			return false
		for k in gd_ids.size():
			var id: int = gd_ids[k]
			if ids[k] != id:
				_fail("tick %d: snapshot id[%d]=%d != gd %d" % [tick, k, ids[k], id])
				return false
			var e: SimEntity = gd.entities[id]
			if snap["type_key"][k] != e.type_key or snap["player"][k] != e.player \
					or snap["kind"][k] != e.kind or snap["x"][k] != e.x or snap["y"][k] != e.y \
					or snap["radius"][k] != e.radius or snap["hp"][k] != e.hp \
					or snap["max_hp"][k] != e.max_hp or snap["amount"][k] != e.amount \
					or snap["build_state"][k] != e.build_state \
					or snap["build_ticks_left"][k] != e.build_ticks_left \
					or snap["foot_w"][k] != e.foot_w or snap["foot_h"][k] != e.foot_h:
				_fail("tick %d viewer %d: entity %d field mismatch" % [tick, viewer, id])
				return false
			var render: bool = e.player == viewer or e.is_resource() \
					or gd.is_entity_visible(viewer, e)
			var want := 0
			if e.morphed: want |= 1
			if e.is_underground(): want |= 2
			if render: want |= 4
			if e.is_unit(): want |= 8
			if e.is_resource(): want |= 16
			if e.kind == SimEntity.Kind.STRUCTURE: want |= 32
			if snap["flags"][k] != want:
				_fail("tick %d viewer %d: entity %d flags %d != %d" %
						[tick, viewer, id, snap["flags"][k], want])
				return false
			# is_entity_visible direct query
			if nat.is_entity_visible(viewer, id) != gd.is_entity_visible(viewer, e):
				_fail("tick %d viewer %d: is_entity_visible(%d) mismatch" % [tick, viewer, id])
				return false

	# fog, resources, bandwidth per player
	for pid in [1, 2]:
		if nat.vision_of(pid) != gd.vision_of(pid):
			_fail("tick %d: vision_of(%d) mismatch" % [tick, pid])
			return false
		var nr: Dictionary = nat.resources_of(pid)
		var gr: Dictionary = gd.resources_of(pid)
		if nr["alloy"] != gr["alloy"] or nr["flux"] != gr["flux"]:
			_fail("tick %d: resources_of(%d) %s != %s" % [tick, pid, nr, gr])
			return false
		var nb: Dictionary = nat.bandwidth_of(pid)
		var gb: Dictionary = gd.bandwidth_of(pid)
		if nb["used"] != gb["used"] or nb["provided"] != gb["provided"]:
			_fail("tick %d: bandwidth_of(%d) %s != %s" % [tick, pid, nb, gb])
			return false

	# match result
	var nm: Dictionary = nat.match_result()
	var gm: Dictionary = gd.match_result()
	if nm["over"] != gm["over"] or nm["winner"] != gm["winner"]:
		_fail("tick %d: match_result %s != %s" % [tick, nm, gm])
		return false
	return true


## Per-interaction console/placement/AI read queries.
func _compare_queries(gd: Sim, nat: Object, tick: int) -> bool:
	if nat.blocked_bytes() != gd.grid.blocked_bytes():
		_fail("tick %d: blocked_bytes mismatch" % tick)
		return false
	if int(nat.grid_tiles_w()) != gd.grid.tiles_w or int(nat.grid_tiles_h()) != gd.grid.tiles_h:
		_fail("tick %d: grid dims mismatch" % tick)
		return false
	for p in [1, 2]:
		if nat.buildable_structures(p) != gd.buildable_structures(p):
			_fail("tick %d: buildable_structures(%d)" % [tick, p]); return false
		if nat.trainable_units(p) != gd.trainable_units(p):
			_fail("tick %d: trainable_units(%d)" % [tick, p]); return false
		if nat.stronghold_ids(p) != gd.stronghold_ids(p):
			_fail("tick %d: stronghold_ids(%d)" % [tick, p]); return false
		if nat.depot_ids(p) != gd.depot_ids(p):
			_fail("tick %d: depot_ids(%d)" % [tick, p]); return false
		if str(nat.training_queues(p)) != str(gd.training_queues(p)):
			_fail("tick %d: training_queues(%d)" % [tick, p]); return false
		for type in gd.buildable_structures(p):
			if int(nat.builder_for(p, type, -1, -1)) != gd.builder_for(p, type):
				_fail("tick %d: builder_for(%d,%d)" % [tick, p, type]); return false
			if str(nat.build_block_reason(p, type)) != gd.build_block_reason(p, type):
				_fail("tick %d: build_block_reason(%d,%d) '%s' != '%s'" %
						[tick, p, type, nat.build_block_reason(p, type), gd.build_block_reason(p, type)]); return false
		for type in gd.trainable_units(p):
			if int(nat.train_structure_for(p, type)) != gd.train_structure_for(p, type):
				_fail("tick %d: train_structure_for(%d,%d)" % [tick, p, type]); return false
		for did in gd.depot_ids(p):
			if str(nat.depot_economy(did)) != str(gd.depot_economy(did)):
				_fail("tick %d: depot_economy(%d)" % [tick, did]); return false
		if str(nat.flagged_aura_circles(p, "territory")) != str(gd.flagged_aura_circles(p, "territory")):
			_fail("tick %d: flagged_aura_circles(%d)" % [tick, p]); return false
		# territory_covers sampled across the map
		for s in [[Fixed.from_int(20), Fixed.from_int(20)], [Fixed.from_int(40), Fixed.from_int(40)],
				[Fixed.from_int(10), Fixed.from_int(50)]]:
			if bool(nat.territory_covers(p, s[0], s[1])) != gd.territory_covers(p, s[0], s[1]):
				_fail("tick %d: territory_covers(%d,%d,%d)" % [tick, p, s[0], s[1]]); return false
		if str(nat.income()) != str(gd.income):
			_fail("tick %d: income mismatch" % tick); return false
	if str(nat.vents()) != str(gd.vents()):
		_fail("tick %d: vents()" % tick); return false
	for v in gd.vents():
		if int(nat.vent_at(v["cx"], v["cy"], v["w"], v["h"])) != gd.vent_at(v["cx"], v["cy"], v["w"], v["h"]):
			_fail("tick %d: vent_at" % tick); return false
		if bool(nat.vent_taken(v["id"])) != gd.vent_taken(v["id"]):
			_fail("tick %d: vent_taken(%d)" % [tick, v["id"]]); return false
	return true
