class_name GameSim
extends RefCounted
## View/UI-facing adapter over the native C++ sim (NativeSim, design_m5.md §2).
## The authoritative simulation is native; this wrapper presents the read surface
## the GDScript view, console, and bot already use (the same shape the frozen
## GDScript Sim exposed), so the rest of the game is unchanged by the swap.
##
## It crosses the boundary O(1) times per tick: step() advances the native sim
## then pulls ONE batch snapshot, from which it rebuilds lightweight SimEntity /
## SimPlayer facades, the grid mirror, and per-stronghold income. Everything the
## view reads is then local GDScript. The native sim owns the real state; these
## facades are a read mirror refreshed each tick (never written back).

var _n: NativeSim

## The compiled catalog (GDScript-side data, passed straight through).
var catalog: CompiledCatalog
## Read mirror of the native grid (geometry + occupancy for the view).
var grid: SimGrid
## id -> SimEntity facade, rebuilt each step (ascending insertion = ascending id).
var entities := {}
## pid -> SimPlayer facade, rebuilt each step.
var players := {}
## sh_id -> {alloy, flux, assist_used, idle_assist, idle}, refreshed each step.
var income := {}
## The viewer whose render visibility is baked into the per-step snapshot.
var local_player := 1

## render-visible (own || resource || seen) for local_player, id -> bool.
var _render_local := {}

var tick: int:
	get:
		return _n.get_tick() if _n != null else 0


func setup(seed_value: int, p_catalog: CompiledCatalog, map: MapData, p_local := 1) -> void:
	_n = ClassDB.instantiate("NativeSim")
	catalog = p_catalog
	local_player = p_local
	_n.construct(seed_value, p_catalog, map)
	grid = SimGrid.new(_n.grid_tiles_w(), _n.grid_tiles_h())
	_refresh()


func step() -> void:
	_n.step()
	_refresh()


## Authoritative state hash (native). Used by desync detection / parity checks.
func state_hash() -> int:
	return _n.state_hash()


## Schedule a SimCommand (the GDScript wire form) onto the native queue.
func schedule(cmd: SimCommand, at_tick: int = -1) -> void:
	_n.schedule(cmd.player_id, cmd.kind, PackedInt32Array(cmd.targets),
			cmd.params, cmd.seq, at_tick)


func _sorted_ids() -> Array:
	var ids := entities.keys()
	ids.sort()
	return ids


# --- per-tick mirror refresh -------------------------------------------------
func _refresh() -> void:
	grid.set_blocked_bytes(_n.blocked_bytes())
	income = _n.income()
	_rebuild_entities()
	_rebuild_players()


func _rebuild_entities() -> void:
	var s: Dictionary = _n.view_snapshot(local_player)
	var ids: PackedInt32Array = s["ids"]
	var type_key: PackedInt32Array = s["type_key"]
	var player: PackedInt32Array = s["player"]
	var kind: PackedByteArray = s["kind"]
	var xs: PackedInt64Array = s["x"]
	var ys: PackedInt64Array = s["y"]
	var radius: PackedInt64Array = s["radius"]
	var hp: PackedInt32Array = s["hp"]
	var max_hp: PackedInt32Array = s["max_hp"]
	var amount: PackedInt64Array = s["amount"]
	var build_state: PackedByteArray = s["build_state"]
	var build_ticks_left: PackedInt64Array = s["build_ticks_left"]
	var foot_x: PackedInt32Array = s["foot_x"]
	var foot_y: PackedInt32Array = s["foot_y"]
	var foot_w: PackedInt32Array = s["foot_w"]
	var foot_h: PackedInt32Array = s["foot_h"]
	var resource_kind: PackedInt32Array = s["resource_kind"]
	var nano_alloy: PackedInt32Array = s["nano_alloy"]
	var nano_flux: PackedInt32Array = s["nano_flux"]
	var nano_assist: PackedInt32Array = s["nano_assist"]
	var flags: PackedInt32Array = s["flags"]

	var next := {}
	_render_local.clear()
	for i in ids.size():
		var e := SimEntity.new()
		e.id = ids[i]
		e.type_key = type_key[i]
		e.player = player[i]
		e.kind = kind[i]
		e.x = xs[i]
		e.y = ys[i]
		e.radius = radius[i]
		e.hp = hp[i]
		e.max_hp = max_hp[i]
		e.amount = amount[i]
		e.build_state = build_state[i]
		e.build_ticks_left = build_ticks_left[i]
		e.foot_x = foot_x[i]
		e.foot_y = foot_y[i]
		e.foot_w = foot_w[i]
		e.foot_h = foot_h[i]
		e.resource_kind = resource_kind[i]
		e.nano_alloc = [nano_alloy[i], nano_flux[i], nano_assist[i]]
		var f: int = flags[i]
		e.morphed = (f & 1) != 0
		e.underground_ticks_left = 1 if (f & 2) != 0 else 0
		e.targetable = (f & 16) == 0  # resources are untargetable
		next[e.id] = e
		_render_local[e.id] = (f & 4) != 0
	entities = next


func _rebuild_players() -> void:
	var snap: Dictionary = _n.players_snapshot()
	var next := {}
	for pid in snap:
		var row: Dictionary = snap[pid]
		var p := SimPlayer.new()
		p.id = row["id"]
		p.faction = row["faction"]
		p.alloy = row["alloy"]
		p.flux = row["flux"]
		p.auto_repair = row["auto_repair"]
		p.eliminated_tick = row["eliminated_tick"]
		p.had_main = row["had_main"]
		next[int(pid)] = p
	players = next


# --- read API passthrough (matches the GDScript Sim surface) -----------------
## Final render visibility for the local player (batch — no per-entity crossing).
func should_render(e: SimEntity) -> bool:
	return _render_local.get(e.id, false)


func is_entity_visible(player: int, e: SimEntity) -> bool:
	return _n.is_entity_visible(player, e.id)


func is_tile_visible(player: int, tx: int, ty: int) -> bool:
	return _n.is_tile_visible(player, tx, ty)


func is_cell_visible(player: int, cx: int, cy: int) -> bool:
	return _n.is_cell_visible(player, cx, cy)


func vision_of(player: int) -> PackedByteArray:
	return _n.vision_of(player)


func resources_of(player: int) -> Dictionary:
	return _n.resources_of(player)


func bandwidth_of(player: int) -> Dictionary:
	return _n.bandwidth_of(player)


func match_result() -> Dictionary:
	return _n.match_result()


func buildable_structures(player: int) -> PackedInt32Array:
	return _n.buildable_structures(player)


func builder_for(player: int, type_key: int, cx: int = -1, cy: int = -1) -> int:
	return _n.builder_for(player, type_key, cx, cy)


func build_block_reason(player: int, type_key: int) -> String:
	return _n.build_block_reason(player, type_key)


func trainable_units(player: int) -> PackedInt32Array:
	return _n.trainable_units(player)


func train_structure_for(player: int, type_key: int) -> int:
	return _n.train_structure_for(player, type_key)


func stronghold_ids(player: int) -> PackedInt32Array:
	return _n.stronghold_ids(player)


func depot_ids(player: int) -> PackedInt32Array:
	return _n.depot_ids(player)


func depot_economy(depot_id: int) -> Dictionary:
	return _n.depot_economy(depot_id)


func training_queues(player: int) -> Array:
	return _n.training_queues(player)


func vents() -> Array:
	return _n.vents()


func vent_at(cx: int, cy: int, w: int, h: int) -> int:
	return _n.vent_at(cx, cy, w, h)


func vent_taken(vent_id: int) -> bool:
	return _n.vent_taken(vent_id)


func territory_covers(player: int, x: int, y: int) -> bool:
	return _n.territory_covers(player, x, y)


func flagged_aura_circles(player: int, flag: String) -> Array:
	return _n.flagged_aura_circles(player, flag)


func _free_cell_near_rect(cx: int, cy: int, w: int, h: int, max_radius: int = 12) -> int:
	return _n.free_cell_near_rect(cx, cy, w, h, max_radius)
