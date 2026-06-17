class_name Sim
extends RefCounted
## The deterministic game simulation. Headless, tick-driven, fixed-point.
##
## Constitution (see design.md "Determinism rules"):
##  - No floats, no engine physics, no node access, no wall-clock time.
##  - All randomness comes from `rng` (procs via ProcRng).
##  - All iteration over entities happens in ascending entity-id order.
##  - The only inputs are the seed at construction and scheduled commands.
##
## Tick order: commands -> movement -> combat -> reap. Movement follows
## design.md "Pathfinding and movement": flow fields / A* supply a desired
## direction, then collision is resolved (circle-circle separation, then
## circle vs blocked cells), then arrival is checked.
##
## The view layer reads sim state to render it but never writes back.

const TICK_RATE := 20
## Commands are scheduled this many ticks after issue (lockstep latency).
const COMMAND_DELAY := 3
## Fog recompute cadence in ticks (design_m3.md §4.4): tick-based so every
## lockstep peer computes identical visibility maps. Worst-case staleness
## is 200 ms — invisible at fog scale; the relief valve if profiling
## disagrees with the budget.
const VISION_PERIOD := 4
## Orders for this many units or fewer get per-unit A* paths; larger
## groups share one flow field per destination.
const SMALL_GROUP := 3
## A move order completes within this distance of the goal (fixed).
const ARRIVE_DIST := SimGrid.CELL
## A path waypoint is considered reached within this distance (fixed). Theta*
## segments are any-angle, so a unit rarely lands exactly on the corner cell;
## this lets it advance once it closes on the corner.
const WAYPOINT_REACH := SimGrid.CELL
## Spatial bucket size for neighbor queries: 2.0 world units.
const BUCKET_SHIFT := Fixed.SHIFT + 1
const FLOW_CACHE_MAX := 32
## Flow-field build budget per tick, in Dijkstra queue pops — an operation
## count, not wall time, so every peer advances builds identically. ~2000
## pops is ~15 ms of GDScript; a full 128x128 build (~21k pops) lands in
## ~11 ticks, while short orders finish within a tick via early exit.
const FLOW_BUILD_POPS_PER_TICK := 2000

## Waypoint sentinel: the active order is unreachable, give up.
const GIVE_UP := Vector2i(-1, -1)

## Within this distance of the shared goal, a unit retargets to its
## personal surround slot (see _surround_slots).
const SLOT_SWITCH_DIST := Fixed.ONE * 3
## At most this many units of a group get personal surround slots (only
## the inner perimeter can touch the target anyway; the rest pile up via
## the cluster radius). Also bounds the O(slots^2 x candidates) pick.
const SLOT_MAX := 24
## A move order whose unit made no progress toward the goal for this many
## ticks, while touching an arrived group-mate, completes where it stands —
## the unit is wedged behind its own crowd and that is de facto arrival.
const STALL_TICKS := 20
## With no progress for this long (and no contact-based completion — e.g.
## steering keeps orbiting an arrived crowd without touching it), the unit
## gives the order up entirely. Long enough that waiting out a flow-field
## build queue or a chokepoint jam doesn't false-trigger.
const STALL_GIVE_UP_TICKS := 60

var tick: int = 0
var rng: DRng
var grid: SimGrid
## Compiled object catalog: the source of every entity's stats. Plain data
## (see CompiledCatalog) — the sim never reads a file.
var catalog: CompiledCatalog
## player id -> SimPlayer (created from map data; 0 is neutral, unlisted).
var players: Dictionary = {}
## entity_id -> SimEntity
var entities: Dictionary = {}

## Cached `construction` armor-class index (design_m4.md §4.3): GROWING and
## CAPSULE structures present it instead of their normal armor, so
## anti-construction units melt them. -1 if the catalog has no such class.
var _construction_armor: int = -1

## Catalog + map content hashes, folded into state_hash() so peers with
## mismatched data files desync at tick 0 with an obvious cause.
var _data_hash: int = 0
var _next_entity_id: int = 1
## tick -> Array[SimCommand]
var _command_queue: Dictionary = {}
## goal cell index -> {"next": PackedInt32Array, "dist": PackedInt32Array,
## "full": bool} from Pathing.flow_field (derived data, not hashed;
## rebuilt whenever grid.version moves).
var _flow_cache: Dictionary = {}
var _flow_version: int = -1
## In-progress incremental builds (Pathing.FlowBuild), FIFO. Units whose
## field is still building hold position until it lands.
var _flow_builds: Array = []
## Vector2i bucket -> Array[int] entity ids, rebuilt each tick.
var _buckets: Dictionary = {}
## Aura source index (design_m3.md §4.3): player -> ability type_key ->
## Array of [owner_id, x, y, radius]. Derived data rebuilt every tick in
## ascending owner id — never hashed, like buckets; the per-tick rebuild
## is also what makes mobile aura owners free.
var _aura_sources: Dictionary = {}
## Per-player visibility at build-tile resolution (§4.4): player ->
## PackedByteArray (1 = visible). Derived from hashed state on a fixed
## tick cadence, so it is itself deterministic but never hashed.
var _vision: Dictionary = {}
## Per-pathing-cell LOS height (design_m4.md §6.5), derived each vision tick.
## _has_occluders gates the height-LOS test so open ground stays the cheap
## M3 disc stamp.
var _occluders := PackedByteArray()
var _has_occluders: bool = false


func _init(seed_value: int, p_catalog: CompiledCatalog, map: MapData) -> void:
	assert(p_catalog != null and p_catalog.ok(), "sim needs a valid catalog")
	rng = DRng.new(seed_value)
	catalog = p_catalog
	_construction_armor = catalog.armor_classes.find("construction")
	grid = SimGrid.new(map.tiles_w, map.tiles_h)
	_data_hash = (catalog.hash_value * 31 + map.hash_value) & 0x7FFFFFFFFFFFFFF
	for p: Dictionary in map.players:
		var sp := SimPlayer.new()
		sp.id = p["id"]
		sp.faction = SimHash.fnv_string(p["faction"])
		sp.alloy = Fixed.from_int(p["start_alloy"])
		sp.flux = Fixed.from_int(p["start_flux"])
		players[sp.id] = sp
	for obj: Dictionary in map.objects:
		match catalog.kind_of(obj["type_key"]):
			"unit":
				spawn_unit(obj["player"], obj["x"], obj["y"], obj["type_key"])
			"structure":
				spawn_structure(obj["player"], obj["cx"], obj["cy"],
						obj["type_key"], obj["completed"])
			"resource":
				spawn_resource(obj["cx"], obj["cy"], obj["type_key"])
	_recompute_vision()


## Schedule a command for execution. Lockstep peers must schedule identical
## commands for identical ticks.
func schedule(cmd: SimCommand, at_tick: int = -1) -> void:
	var t := at_tick if at_tick >= 0 else tick + COMMAND_DELAY
	assert(t >= tick, "cannot schedule a command in the past")
	if not _command_queue.has(t):
		_command_queue[t] = []
	_command_queue[t].append(cmd)


## Advance the sim by exactly one tick. Tick order (design_m3.md §4):
## commands -> economy -> production -> movement -> combat -> structures
## -> reap -> vision (every VISION_PERIOD ticks).
func step() -> void:
	_rebuild_aura_index()
	_execute_scheduled_commands()
	_economy_system()
	_worker_economy_system()
	_worker_build_system()
	_production_system()
	_run_flow_builds()
	_movement_system()
	_combat_system()
	_stance_system()
	_status_system()
	_structures_system()
	_reap()
	_check_elimination()
	tick += 1
	if tick % VISION_PERIOD == 0:
		_recompute_vision()


## Scenario setup helper (map load / tests). Stats come from the catalog;
## positions are fixed-point world coordinates.
func spawn_unit(player: int, x: int, y: int, type_key: int) -> int:
	assert(catalog.kind_of(type_key) == "unit")
	var s := catalog.sim_of(type_key)
	var e := SimEntity.new()
	e.id = _next_entity_id
	_next_entity_id += 1
	e.kind = SimEntity.Kind.UNIT
	e.type_key = type_key
	e.player = player
	e.x = x
	e.y = y
	_copy_combat_stats(e, s)
	e.radius = s["radius"]
	e.step = int(s["speed"]) / TICK_RATE
	e.crit_base = s["crit_base"]
	e.crit_bonus = s["crit_bonus"]
	entities[e.id] = e
	return e.id


## Footprint comes from the catalog, in pathing cells (drawn walls are
## 1x1-cell structures; nothing assumes a structure is at least a tile
## big). Returns 0 if any footprint cell is blocked. `completed` false
## starts the structure GROWING (10% hp, full build time).
func spawn_structure(player: int, cx: int, cy: int, type_key: int,
		completed: bool = true) -> int:
	assert(catalog.kind_of(type_key) == "structure")
	var s := catalog.sim_of(type_key)
	if not grid.rect_free(cx, cy, s["foot_w"], s["foot_h"]):
		return 0
	return _spawn_structure_entity(player, cx, cy, type_key, completed, 0).id


## Places a structure without checking occupancy — callers validate
## (spawn_structure checks rect_free; the BUILD path has its own
## vision-gated rules, and vent builds deliberately overlap the vent).
func _spawn_structure_entity(player: int, cx: int, cy: int, type_key: int,
		completed: bool, vent_id: int) -> SimEntity:
	var s := catalog.sim_of(type_key)
	var e := _place_footprint(player, cx, cy, type_key, s)
	e.kind = SimEntity.Kind.STRUCTURE
	_copy_combat_stats(e, s)
	e.vent_id = vent_id
	if completed:
		e.build_state = SimEntity.BuildState.COMPLETE
		_on_structure_complete(e)
	else:
		e.build_state = SimEntity.BuildState.GROWING
		e.build_ticks_left = Fixed.from_int(s["build_time"])
		e.hp = maxi(1, e.max_hp / 10)
	return e


## Resource nodes block their footprint, are untargetable, and never act
## (design_m3.md §4.2). `amount` is kept in fixed point so fractional
## per-tick extraction decrements exactly.
func spawn_resource(cx: int, cy: int, type_key: int) -> int:
	assert(catalog.kind_of(type_key) == "resource")
	var s := catalog.sim_of(type_key)
	var e := _place_footprint(0, cx, cy, type_key, s)
	e.kind = SimEntity.Kind.RESOURCE
	e.targetable = false
	e.hp = 1
	e.max_hp = 1
	e.amount = Fixed.from_int(s["amount"])
	e.resource_kind = s["resource"]
	return e.id


## Shared footprint placement: blocks the rect and positions the entity at
## its center. Caller checks rect_free first if placement can fail.
func _place_footprint(player: int, cx: int, cy: int, type_key: int,
		s: Dictionary) -> SimEntity:
	var e := SimEntity.new()
	e.id = _next_entity_id
	_next_entity_id += 1
	e.type_key = type_key
	e.player = player
	e.foot_x = cx
	e.foot_y = cy
	e.foot_w = s["foot_w"]
	e.foot_h = s["foot_h"]
	e.x = cx * SimGrid.CELL + e.foot_w * SimGrid.CELL / 2
	e.y = cy * SimGrid.CELL + e.foot_h * SimGrid.CELL / 2
	# Circle approximation of the footprint for range checks.
	e.radius = mini(e.foot_w, e.foot_h) * SimGrid.CELL / 2
	grid.block_rect(cx, cy, e.foot_w, e.foot_h)
	e.blocks = true
	entities[e.id] = e
	return e


func _copy_combat_stats(e: SimEntity, s: Dictionary) -> void:
	e.hp = s["hp"]
	e.max_hp = s["hp"]
	e.damage = s["damage"]
	e.attack_range = s["attack_range"]
	e.acquire_range = s["acquire_range"]
	e.cooldown_ticks = s["cooldown"]
	e.sight = s["sight"]
	e.hits_air = s["hits_air"]
	e.attack_class = s["attack_class"]
	e.armor_class = s["armor_class"]
	e.damage_taken = s.get("damage_taken", Fixed.ONE)


func _sorted_ids() -> Array:
	var ids := entities.keys()
	ids.sort()
	return ids


# --- commands ---------------------------------------------------------------


## Order-insensitive inputs are sorted so every peer executes identically.
func _execute_scheduled_commands() -> void:
	if not _command_queue.has(tick):
		return
	var commands: Array = _command_queue[tick]
	_command_queue.erase(tick)
	commands.sort_custom(func(a: SimCommand, b: SimCommand) -> bool:
		if a.player_id != b.player_id:
			return a.player_id < b.player_id
		return a.seq < b.seq)
	for cmd in commands:
		_execute(cmd)


func _execute(cmd: SimCommand) -> void:
	match cmd.kind:
		SimCommand.Kind.MOVE, SimCommand.Kind.ATTACK_MOVE:
			_order_move(cmd)
		SimCommand.Kind.STOP:
			for e in _own_units(cmd):
				e.orders.clear()
				e.path = PackedInt32Array()
				e.path_i = 0
				e.goal_key = -1
				e.target_id = 0
		SimCommand.Kind.BUILD:
			_execute_build(cmd)
		SimCommand.Kind.ALLOCATE_ECONOMY:
			_execute_allocate(cmd)
		SimCommand.Kind.TRAIN:
			_execute_train(cmd)
		SimCommand.Kind.CANCEL:
			_execute_cancel(cmd)
		SimCommand.Kind.SET_RALLY:
			_execute_set_rally(cmd)
		SimCommand.Kind.PATROL:
			_execute_patrol(cmd)
		SimCommand.Kind.SET_TACTIC:
			_execute_set_tactic(cmd)
		SimCommand.Kind.ABILITY:
			_execute_ability(cmd)
		SimCommand.Kind.MINE:
			_execute_mine(cmd)
		SimCommand.Kind.SET_ECONOMY:
			_execute_set_economy(cmd)
		SimCommand.Kind.BUILD_WALL:
			_execute_build_wall(cmd)
		SimCommand.Kind.REPAIR:
			_execute_repair(cmd)
		SimCommand.Kind.DEBUG_SPAWN:
			spawn_unit(cmd.player_id,
					cmd.params.get("x", 0), cmd.params.get("y", 0),
					cmd.params.get("type", -1))
		_:
			pass # Remaining kinds land in M3+.


# --- BUILD (design_m3.md §4.5) ------------------------------------------------


## Vision-gated build validation. Commands are requests: every failed
## check is a silent no-op — the UI predicts validity, and a stale
## prediction must not crash lockstep. Cells under fog are taken on faith;
## the capsule discovers the truth at landing.
func _execute_build(cmd: SimCommand) -> void:
	var player: SimPlayer = players.get(cmd.player_id)
	if player == null or cmd.targets.is_empty():
		return
	var builder: SimEntity = entities.get(cmd.targets[0])
	if not _functional(builder) or builder.player != cmd.player_id:
		return
	var type: int = cmd.params.get("type", -1)
	if type < 0 or type >= catalog.size() or catalog.kind_of(type) != "structure":
		return
	var mechanic := _build_mechanic_for(builder, type)
	if mechanic == -1:
		return
	var s := catalog.sim_of(type)
	var w: int = s["foot_w"]
	var h: int = s["foot_h"]
	var cx: int = cmd.params.get("cx", -1)
	var cy: int = cmd.params.get("cy", -1)
	if cx < 0 or cy < 0 or cx + w > grid.width or cy + h > grid.height:
		return

	# Worker mechanic (design_m4.md §4.1): no capsule, no surcharge, no fog
	# gamble — the worker walks to ground it can legally reach and place on.
	if mechanic == CatalogSchema.BuildMechanic.WORKER:
		_execute_worker_build(cmd.player_id, builder, type, cx, cy, w, h)
		return

	# Siphon placement: the footprint must exactly cover a free vent
	# (instead of requiring free cells — the vent itself blocks them).
	var vent_id := 0
	if s["builds_on_vent"]:
		vent_id = _vent_at(cx, cy, w, h)
		if vent_id == 0 or _siphon_on(vent_id) != 0:
			return

	var site_x := cx * SimGrid.CELL + w * SimGrid.CELL / 2
	var site_y := cy * SimGrid.CELL + h * SimGrid.CELL / 2
	var inside := in_flagged_aura(cmd.player_id, "territory", site_x, site_y)
	# requires_territory structures only exist inside influence — they
	# never fly a capsule, so the surcharge can't apply to them either.
	if s["requires_territory"] and not inside:
		return
	var cost_alloy: int = s["cost_alloy"] + (0 if inside else s["capsule_cost_alloy"])
	var cost_flux: int = s["cost_flux"]
	if player.alloy < Fixed.from_int(cost_alloy) \
			or player.flux < Fixed.from_int(cost_flux):
		return

	if not s["builds_on_vent"]:
		if inside:
			# Own territory is always visible (a structure's sight covers
			# its aura), so the instant-GROWING path is fully validated.
			if not grid.rect_free(cx, cy, w, h):
				return
		else:
			# You can never build on ground you can SEE is occupied; you
			# can always TRY ground you can't see.
			for fy in range(cy, cy + h):
				for fx in range(cx, cx + w):
					if is_cell_visible(cmd.player_id, fx, fy) \
							and grid.is_blocked(fx, fy):
						return

	player.alloy -= Fixed.from_int(cost_alloy)
	player.flux -= Fixed.from_int(cost_flux)
	if inside:
		_spawn_structure_entity(cmd.player_id, cx, cy, type, false, vent_id)
	else:
		_spawn_capsule(cmd.player_id, cx, cy, type, vent_id)


## True if the builder carries a build ability whose `structures` list sells
## `type` (design_m3.md §4.5).
func _build_ability_for(builder: SimEntity, type: int) -> bool:
	return _build_mechanic_for(builder, type) != -1


## The `mechanic` of the builder's first build ability that sells `type`
## (CAPSULE or WORKER), or -1 if it carries none.
func _build_mechanic_for(builder: SimEntity, type: int) -> int:
	for ak in _abilities_of(builder):
		var ab := catalog.sim_of(ak)
		if ab["ability_kind"] == CatalogSchema.AbilityKind.BUILD \
				and type in ab["structures"]:
			return ab["mechanic"]
	return -1


## Worker build (design_m4.md §4.1): validate on visible, free, reachable
## ground (no fog gamble), reserve the cost, spawn the structure GROWING but
## frozen (needs_builder) — it blocks its footprint and presents
## `construction` armor at once — then send the worker to raise it.
func _execute_worker_build(player_id: int, builder: SimEntity, type: int,
		cx: int, cy: int, w: int, h: int) -> void:
	var player: SimPlayer = players.get(player_id)
	if player == null:
		return
	var s := catalog.sim_of(type)
	# Occupancy + vision: a worker can only be ordered onto ground the player
	# can see is free (the asymmetry with the Hive's fog gamble).
	for fy in range(cy, cy + h):
		for fx in range(cx, cx + w):
			if grid.is_blocked(fx, fy) or not is_cell_visible(player_id, fx, fy):
				return
	if player.alloy < Fixed.from_int(s["cost_alloy"]) \
			or player.flux < Fixed.from_int(s["cost_flux"]):
		return
	player.alloy -= Fixed.from_int(s["cost_alloy"])
	player.flux -= Fixed.from_int(s["cost_flux"])
	var site := _spawn_structure_entity(player_id, cx, cy, type, false, 0)
	site.needs_builder = true
	builder.build_target = site.id
	builder.orders.clear()
	_move_to_entity(builder, site)


## The flux vent whose footprint exactly matches the rect, or 0.
func _vent_at(cx: int, cy: int, w: int, h: int) -> int:
	for id in _sorted_ids():
		var e: SimEntity = entities[id]
		if e.is_resource() and e.resource_kind == CatalogSchema.ResourceKind.FLUX \
				and e.foot_x == cx and e.foot_y == cy \
				and e.foot_w == w and e.foot_h == h:
			return id
	return 0


## A live siphon (any build state — a growing one claims the vent too)
## linked to this vent, or 0.
func _siphon_on(vent_id: int) -> int:
	for id in _sorted_ids():
		var e: SimEntity = entities[id]
		if e.kind == SimEntity.Kind.STRUCTURE and e.hp > 0 and e.vent_id == vent_id:
			return id
	return 0


## An airborne capsule at the target site: does not block pathing, cannot
## act, projects no sight; targetable but aerial. No timeout and no recall
## (§4.5).
func _spawn_capsule(player: int, cx: int, cy: int, type_key: int,
		vent_id: int) -> void:
	var s := catalog.sim_of(type_key)
	var e := SimEntity.new()
	e.id = _next_entity_id
	_next_entity_id += 1
	e.kind = SimEntity.Kind.STRUCTURE
	e.type_key = type_key
	e.player = player
	e.foot_x = cx
	e.foot_y = cy
	e.foot_w = s["foot_w"]
	e.foot_h = s["foot_h"]
	e.x = cx * SimGrid.CELL + e.foot_w * SimGrid.CELL / 2
	e.y = cy * SimGrid.CELL + e.foot_h * SimGrid.CELL / 2
	e.radius = mini(e.foot_w, e.foot_h) * SimGrid.CELL / 2
	_copy_combat_stats(e, s)
	e.damage = 0 # capsules never fight, whatever the finished form does
	e.hp = catalog.globals["capsule_hp"]
	e.build_state = SimEntity.BuildState.CAPSULE
	e.build_ticks_left = Fixed.from_int(catalog.globals["capsule_time"])
	e.vent_id = vent_id
	entities[e.id] = e


func _execute_allocate(cmd: SimCommand) -> void:
	if cmd.targets.is_empty():
		return
	var e: SimEntity = entities.get(cmd.targets[0])
	if not _functional(e) or e.player != cmd.player_id \
			or e.kind != SimEntity.Kind.STRUCTURE:
		return
	var pool: int = catalog.sim_of(e.type_key)["nano_pool"]
	if pool <= 0:
		return
	var a: int = cmd.params.get("alloy", 0)
	var f: int = cmd.params.get("flux", 0)
	var s: int = cmd.params.get("assist", 0)
	if a < 0 or f < 0 or s < 0 or a + f + s > pool:
		return # rejected outright (§4.9), never clamped silently
	e.nano_alloc = [a, f, s]


## The command's own live units, ascending id.
func _own_units(cmd: SimCommand) -> Array[SimEntity]:
	var ts := cmd.targets.duplicate()
	ts.sort()
	var result: Array[SimEntity] = []
	for id in ts:
		var e: SimEntity = entities.get(id)
		if e != null and e.hp > 0 and e.is_unit() and e.player == cmd.player_id:
			result.append(e)
	return result


func _order_move(cmd: SimCommand) -> void:
	var units := _own_units(cmd)
	if units.is_empty():
		return
	var queued: bool = cmd.params.get("queue", false)
	# A player-issued order pulls a worker off its current task (harvest/build/
	# wall, design_m4.md §4.1); internal sim moves (harvest/build travel) don't.
	if not cmd.params.get("internal", false):
		for e in units:
			e.build_target = 0
			e.wall_target_cell = -1
			if _is_worker(e):
				e.harvest_state = SimEntity.HarvestState.IDLE
				e.assigned_source = 0
	var small := units.size() <= SMALL_GROUP
	var tx: int = clampi(cmd.params.get("x", 0),
			SimGrid.CELL / 2, grid.world_w() - SimGrid.CELL / 2)
	var ty: int = clampi(cmd.params.get("y", 0),
			SimGrid.CELL / 2, grid.world_h() - SimGrid.CELL / 2)
	var gcx := clampi(grid.cell_of(tx), 0, grid.width - 1)
	var gcy := clampi(grid.cell_of(ty), 0, grid.height - 1)
	# Shared identity of this destination for crowd arrival — units that
	# completed the same group key count as "arrived here".
	var group_key := grid.index(gcx, gcy)
	# Ordering a group onto a blocked footprint (structure, scenery)
	# surrounds it: each unit gets a personal slot cell on the perimeter.
	var slots: Array[int] = []
	if units.size() > 1 and grid.is_blocked(gcx, gcy):
		slots = _surround_slots(gcx, gcy, units)
	# Prebuild the shared flow field with every unit's cell as a source, so
	# the early exit covers the whole group and the per-unit _start_order
	# calls below all hit the cache.
	if not small:
		var goal := grid.nearest_free_cell(gcx, gcy)
		if goal != -1:
			var cells := PackedInt32Array()
			for e in units:
				cells.append(_cell_index_of(e))
			_flow_entry(goal, cells)
	# Crowd arrivals may complete this far from the goal: enough annulus to
	# pack the whole group (radius grows ~sqrt(N)), no further — otherwise
	# arrivals chain outward in a line instead of clustering.
	var pack_rings := _isqrt(units.size()) + 1
	for i in units.size():
		var e := units[i]
		var order := {
			"kind": cmd.kind,
			"x": tx,
			"y": ty,
			"small": small,
			"group": group_key,
			"cluster": ARRIVE_DIST + e.radius * 2 * pack_rings,
		}
		if not slots.is_empty() and slots[i] != -1:
			order["slot_x"] = grid.cell_center(slots[i] % grid.width)
			order["slot_y"] = grid.cell_center(slots[i] / grid.width)
		if queued and not e.orders.is_empty():
			e.orders.append(order)
		else:
			e.orders.clear()
			e.orders.append(order)
			e.target_id = 0
			_start_order(e)


## Personal destination cells around a blocked goal cell, so a group
## ordered onto a structure surrounds it instead of piling on the near
## face. Candidates are the free cells on rings around the goal; up to
## SLOT_MAX of them are picked spread-first (nearest the approaching
## group, then greedy farthest-point so the far side fills). Slots go to
## the units nearest the goal (they arrive first); each takes the nearest
## unclaimed pick. Returns cell indices parallel to `units`, -1 for units
## without a slot; empty if no free cells nearby (callers fall back to the
## plain shared goal).
func _surround_slots(gcx: int, gcy: int, units: Array[SimEntity]) -> Array[int]:
	var n_slots := mini(units.size(), SLOT_MAX)
	var cand: Array[Vector2i] = []
	var r := 1
	while cand.size() < n_slots and r <= 12:
		for dy in range(-r, r + 1):
			for dx in range(-r, r + 1):
				if maxi(absi(dx), absi(dy)) != r:
					continue
				var x := gcx + dx
				var y := gcy + dy
				if grid.in_bounds(x, y) and not grid.is_blocked(x, y):
					cand.append(Vector2i(x, y))
		r += 1
	if cand.is_empty():
		return []

	var centroid := Vector2i.ZERO
	for e in units:
		centroid += Vector2i(grid.cell_of(e.x), grid.cell_of(e.y))
	centroid /= units.size()

	var picked: Array[Vector2i] = []
	var used: Array[bool] = []
	used.resize(cand.size())
	used.fill(false)
	while picked.size() < n_slots:
		var best := -1
		var best_score := -(1 << 60)
		for i in cand.size():
			if used[i]:
				continue
			var score := -_cell_dist2(cand[i], centroid) if picked.is_empty() \
					else _min_dist2_to(cand[i], picked)
			if score > best_score:
				best = i
				best_score = score
		if best == -1: # fewer free cells than slots: share them round-robin
			picked.append(cand[picked.size() % cand.size()])
			continue
		used[best] = true
		picked.append(cand[best])

	# Slots go to the units nearest the goal; ties to the lower index
	# (= lower id, since units arrive sorted).
	var by_dist: Array[int] = []
	for i in units.size():
		by_dist.append(i)
	var goal := Vector2i(gcx, gcy)
	by_dist.sort_custom(func(a: int, b: int) -> bool:
		var da := _cell_dist2(Vector2i(grid.cell_of(units[a].x), grid.cell_of(units[a].y)), goal)
		var db := _cell_dist2(Vector2i(grid.cell_of(units[b].x), grid.cell_of(units[b].y)), goal)
		if da != db:
			return da < db
		return a < b)

	var result: Array[int] = []
	result.resize(units.size())
	result.fill(-1)
	var taken: Array[bool] = []
	taken.resize(picked.size())
	taken.fill(false)
	for k in n_slots:
		var ui := by_dist[k]
		var ec := Vector2i(grid.cell_of(units[ui].x), grid.cell_of(units[ui].y))
		var best := -1
		var best_d := 0
		for j in picked.size():
			if taken[j]:
				continue
			var d := _cell_dist2(ec, picked[j])
			if best == -1 or d < best_d:
				best = j
				best_d = d
		taken[best] = true
		result[ui] = grid.index(picked[best].x, picked[best].y)
	return result


func _cell_dist2(a: Vector2i, b: Vector2i) -> int:
	var dx := a.x - b.x
	var dy := a.y - b.y
	return dx * dx + dy * dy


func _min_dist2_to(c: Vector2i, picked: Array[Vector2i]) -> int:
	var m := 1 << 60
	for p in picked:
		m = mini(m, _cell_dist2(c, p))
	return m


## Activate the front of the order queue: snap the goal to a free cell and
## prepare a path (A* for small orders, flow field otherwise). Unreachable
## orders are dropped and the next queued order activates.
func _start_order(e: SimEntity) -> void:
	e.path = PackedInt32Array()
	e.path_i = 0
	e.goal_key = -1
	e.goal_d2_best = 0x7FFFFFFFFFFFFFF
	e.stall = 0
	while not e.orders.is_empty():
		var o: Dictionary = e.orders[0]
		o["x"] = clampi(o["x"], SimGrid.CELL / 2, grid.world_w() - SimGrid.CELL / 2)
		o["y"] = clampi(o["y"], SimGrid.CELL / 2, grid.world_h() - SimGrid.CELL / 2)
		var gx := clampi(grid.cell_of(o["x"]), 0, grid.width - 1)
		var gy := clampi(grid.cell_of(o["y"]), 0, grid.height - 1)
		var goal := grid.nearest_free_cell(gx, gy)
		if goal != -1:
			if goal != grid.index(gx, gy):
				o["x"] = grid.cell_center(goal % grid.width)
				o["y"] = grid.cell_center(goal / grid.width)
			var from := _cell_index_of(e)
			if from == goal:
				e.goal_key = goal
				return
			if o["small"]:
				e.path = Pathing.theta_star(grid, from, goal)
				if not e.path.is_empty():
					e.goal_key = goal
					return
				# A start cell inside a blocked footprint can't seed A*;
				# fall back to direct steering rather than dropping.
				if grid.is_blocked_index(from):
					e.goal_key = goal
					return
			else:
				var entry := _flow_entry(goal, PackedInt32Array([from]))
				if entry.is_empty():
					# Field still building: accept provisionally; if the
					# goal turns out unreachable, _waypoint returns GIVE_UP
					# once the field lands and the order drops then.
					e.goal_key = goal
					return
				var flow: PackedInt32Array = entry["next"]
				if flow[from] != -1 or grid.is_blocked_index(from):
					e.goal_key = goal
					return
		e.orders.pop_front() # unreachable; try the next queued order
	# queue exhausted, stay idle


func _cell_index_of(e: SimEntity) -> int:
	var cx := clampi(grid.cell_of(e.x), 0, grid.width - 1)
	var cy := clampi(grid.cell_of(e.y), 0, grid.height - 1)
	return grid.index(cx, cy)


## Ready flow-field entry for `goal_index`, guaranteed to either cover
## every cell in `need` or be a full build (where uncovered means truly
## unreachable). Returns {} while the field is still building — callers
## hold position and retry next tick. Blocked cells in `need` are ignored
## (they can never be covered). First build early-exits once `need` is
## settled; a later coverage miss on that partial field triggers one full
## rebuild.
func _flow_entry(goal_index: int, need: PackedInt32Array) -> Dictionary:
	if grid.version != _flow_version:
		_flow_cache.clear()
		_flow_version = grid.version
	var entry: Dictionary = _flow_cache.get(goal_index, {})
	if not entry.is_empty():
		if entry["full"]:
			return entry
		var dist: PackedInt32Array = entry["dist"]
		var covered := true
		for c in need:
			if dist[c] == Pathing.UNREACHABLE and c != goal_index \
					and not grid.is_blocked_index(c):
				covered = false
				break
		if covered:
			return entry
		# Partial field doesn't cover the query: full rebuild.
		_flow_cache.erase(goal_index)
		_request_flow(goal_index, PackedInt32Array())
		return {}
	_request_flow(goal_index, need)
	return {}


func _request_flow(goal_index: int, sources: PackedInt32Array) -> void:
	for b: Pathing.FlowBuild in _flow_builds:
		if b.goal_index == goal_index and b.grid_version == grid.version:
			return
	_flow_builds.append(Pathing.FlowBuild.new(grid, goal_index, sources))


## Advance pending builds within the per-tick pop budget (FIFO).
func _run_flow_builds() -> void:
	var budget := FLOW_BUILD_POPS_PER_TICK
	while budget > 0 and not _flow_builds.is_empty():
		var build: Pathing.FlowBuild = _flow_builds[0]
		if build.grid_version != grid.version:
			_flow_builds.pop_front() # stale; users will re-request
			continue
		budget -= build.run(budget)
		if not build.done:
			return
		_flow_builds.pop_front()
		if _flow_cache.size() >= FLOW_CACHE_MAX:
			_flow_cache.clear()
		_flow_cache[build.goal_index] = {
			"next": build.next, "dist": build.dist, "full": build.full,
		}


# --- movement ---------------------------------------------------------------


func _movement_system() -> void:
	var ids := _sorted_ids()

	# 1. Buckets over the previous tick's resting positions, for steering.
	_rebuild_buckets(ids)

	# 2. Integrate desired velocity from path / flow field, sliding
	#    tangentially around stationary units (boids-lite avoidance) so
	#    movers wrap around a settled crowd instead of plowing into it.
	for id in ids:
		var e: SimEntity = entities[id]
		if not e.is_unit() or e.hp <= 0 or e.orders.is_empty():
			continue
		if e.is_underground() or e.morph_ticks_left > 0:
			continue # burrowed/mid-morph units don't move (§4.8)
		var o: Dictionary = e.orders[0]
		if o["kind"] == SimCommand.Kind.ATTACK_MOVE and _engaged(e):
			continue # stand and fight
		# Near the shared goal, retarget to this unit's personal surround
		# slot: a short A* leg that wraps around the obstacle if the slot
		# is on the far side.
		if o.has("slot_x"):
			var gdx: int = o["x"] - e.x
			var gdy: int = o["y"] - e.y
			if absi(gdx) <= SLOT_SWITCH_DIST and absi(gdy) <= SLOT_SWITCH_DIST \
					and _length(gdx, gdy) <= SLOT_SWITCH_DIST:
				o["x"] = o["slot_x"]
				o["y"] = o["slot_y"]
				o.erase("slot_x")
				o.erase("slot_y")
				o["small"] = true
				# Tighten the crowd-arrival cap: with a personal slot the
				# unit should keep wrapping around the obstacle, not stop
				# in the near-side pile — unless its own slot is taken.
				o["cluster"] = ARRIVE_DIST + e.radius * 2
				_start_order(e)
				if e.orders.is_empty():
					continue
				o = e.orders[0]
		var wp := _waypoint(e, o)
		if wp == GIVE_UP:
			_drop_order(e)
			continue
		var dx := wp.x - e.x
		var dy := wp.y - e.y
		var d := _length(dx, dy)
		if d <= e.step:
			e.x = wp.x
			e.y = wp.y
		elif d > 0:
			var s := _steer_around(e, dx, dy, d)
			var sd := _length(s.x, s.y)
			if sd > 0:
				e.x += s.x * e.step / sd
				e.y += s.y * e.step / sd

	# 3. Rebuild buckets over the new positions (also used by combat).
	_rebuild_buckets(ids)

	# 4. Pairwise separation of overlapping circles, plus crowd arrival:
	#    touching a unit that already completed the same goal (within the
	#    order's cluster radius) completes yours too — otherwise crowds
	#    shove forever at a full destination.
	var crowd_done: Array[int] = []
	for id in ids:
		var e: SimEntity = entities[id]
		if not e.is_unit() or e.hp <= 0 or e.is_underground():
			continue
		for nid in _bucket_neighbors(e, 1, id):
			var n: SimEntity = entities[nid]
			if not n.is_unit() or n.hp <= 0:
				continue
			var dx := n.x - e.x
			var dy := n.y - e.y
			var rr := e.radius + n.radius
			if absi(dx) >= rr or absi(dy) >= rr:
				continue
			# Squared compare first: resting-contact pairs (the common case
			# in a settled crowd) never pay for a sqrt.
			var d2 := Fixed.mul(dx, dx) + Fixed.mul(dy, dy)
			if d2 >= Fixed.mul(rr, rr):
				continue
			var d := Fixed.sqrt(d2)
			if d == 0:
				e.x -= (rr - d) / 2
				n.x += (rr - d) / 2
			else:
				var push := (rr - d) / 2
				e.x -= dx * push / d
				e.y -= dy * push / d
				n.x += dx * push / d
				n.y += dy * push / d
			if _arrived_neighbor(e, n):
				crowd_done.append(e.id)
			if _arrived_neighbor(n, e):
				crowd_done.append(n.id)

	# 5. Push circles out of blocked cells; final map clamp.
	for id in ids:
		var e: SimEntity = entities[id]
		if not e.is_unit() or e.hp <= 0 or e.is_underground():
			continue
		_push_out_of_blocked(e)
		e.x = clampi(e.x, e.radius, grid.world_w() - e.radius)
		e.y = clampi(e.y, e.radius, grid.world_h() - e.radius)

	# 6. Arrival. Dedupe crowd completions: a unit shoved by several
	# arrived neighbors must complete its order exactly once.
	crowd_done.sort()
	var prev_done := 0
	for id in crowd_done:
		if id == prev_done:
			continue
		prev_done = id
		var e: SimEntity = entities[id]
		if not e.orders.is_empty():
			_complete_order(e)
	for id in ids:
		var e: SimEntity = entities[id]
		if not e.is_unit() or e.hp <= 0 or e.orders.is_empty():
			continue
		var o: Dictionary = e.orders[0]
		var dx: int = o["x"] - e.x
		var dy: int = o["y"] - e.y
		var d2 := Fixed.mul(dx, dx) + Fixed.mul(dy, dy)
		if d2 <= Fixed.mul(ARRIVE_DIST, ARRIVE_DIST):
			_complete_order(e)
		elif o["kind"] == SimCommand.Kind.ATTACK_MOVE and e.target_id != 0:
			e.stall = 0 # fighting on the way counts as progress
		elif d2 < e.goal_d2_best:
			e.goal_d2_best = d2
			e.stall = 0
		else:
			e.stall += 1
			if e.stall >= STALL_GIVE_UP_TICKS:
				_drop_order(e)


## Next point to steer toward for the active order, or GIVE_UP if the goal
## is unreachable from here.
func _waypoint(e: SimEntity, o: Dictionary) -> Vector2i:
	var cur := _cell_index_of(e)
	if cur == e.goal_key:
		return Vector2i(o["x"], o["y"])
	if not e.path.is_empty():
		# Re-join the path at the furthest cell we're standing in, so a
		# collision shove forward never walks the unit backward.
		for i in range(e.path_i, e.path.size()):
			if e.path[i] == cur:
				e.path_i = i + 1
		# Then consume any leading waypoints we've already closed on. Theta*
		# corners are any-angle, so we seldom land exactly in the corner cell;
		# advance one at a time (never skipping ahead to a far waypoint).
		while e.path_i < e.path.size():
			var pc := e.path[e.path_i]
			var px := grid.cell_center(pc % grid.width)
			var py := grid.cell_center(pc / grid.width)
			if _length(px - e.x, py - e.y) <= WAYPOINT_REACH:
				e.path_i += 1
			else:
				break
		if e.path_i >= e.path.size():
			return Vector2i(o["x"], o["y"])
		var c := e.path[e.path_i]
		return Vector2i(grid.cell_center(c % grid.width), grid.cell_center(c / grid.width))
	if grid.is_blocked_index(cur):
		# Inside a freshly-placed footprint; steer at the goal and let the
		# push-out pass free us.
		return Vector2i(o["x"], o["y"])
	var entry := _flow_entry(e.goal_key, PackedInt32Array([cur]))
	if entry.is_empty():
		return Vector2i(e.x, e.y) # field still building: hold position
	return _flow_waypoint(e, entry, cur)


## Heading for a unit following the shared flow field. Instead of stepping
## toward next[cur] (one of only 8 directions), descend the local gradient of
## the cost field for an any-angle direction. Falls back to next[cur]'s center
## where the gradient is flat, and reports GIVE_UP when the goal is
## unreachable from here.
func _flow_waypoint(e: SimEntity, entry: Dictionary, cur: int) -> Vector2i:
	var nxt: int = entry["next"][cur]
	if nxt == -1:
		return GIVE_UP
	var dist: PackedInt32Array = entry["dist"]
	var cx := cur % grid.width
	var cy := cur / grid.width
	var gx := _grad_axis(dist, cx, cy, 1, 0)
	var gy := _grad_axis(dist, cx, cy, 0, 1)
	if gx == 0 and gy == 0:
		# Flat field (e.g. hard against a blocker): use the discrete step.
		return Vector2i(grid.cell_center(nxt % grid.width), grid.cell_center(nxt / grid.width))
	# gx/gy are small cost differences; scale them to a real offset so the
	# mover (which normalizes) reads only the direction, well past one step.
	return Vector2i(e.x + gx * SimGrid.CELL, e.y + gy * SimGrid.CELL)


## One axis of the cost-field gradient at (cx, cy), measured along (dx, dy):
## positive points toward the lower-cost (closer-to-goal) side. Central
## difference where both neighbors are usable; one-sided where only one is (so
## headings near a wall lean away from it, not into it); 0 where neither is.
func _grad_axis(dist: PackedInt32Array, cx: int, cy: int, dx: int, dy: int) -> int:
	var here: int = dist[cy * grid.width + cx]
	var back := _cost_at(dist, cx - dx, cy - dy)
	var fwd := _cost_at(dist, cx + dx, cy + dy)
	if back != -1 and fwd != -1:
		return back - fwd
	if fwd != -1:
		return here - fwd
	if back != -1:
		return back - here
	return 0


## Settled cost at a neighbor cell, or -1 if it is off the grid, blocked, or
## not yet reached — so the gradient ignores cells it must not steer into.
func _cost_at(dist: PackedInt32Array, cx: int, cy: int) -> int:
	if cx < 0 or cy < 0 or cx >= grid.width or cy >= grid.height:
		return -1
	var i := cy * grid.width + cx
	if grid.is_blocked_index(i):
		return -1
	var d: int = dist[i]
	if d == Pathing.UNREACHABLE:
		return -1
	return d


## Boids-lite local avoidance: if the desired direction (dx, dy, length d)
## runs into a stationary unit within a few ticks of travel, steer along
## the tangent of the nearest blocker (the side that agrees with the
## current heading; ties break counterclockwise). Returns the steer vector,
## un-normalized — the caller rescales to step length.
func _steer_around(e: SimEntity, dx: int, dy: int, d: int) -> Vector2i:
	var lookahead := e.step * 4
	var best: SimEntity = null
	var best_d2 := 0
	for nid in _bucket_neighbors(e, 1, 0):
		var n: SimEntity = entities[nid]
		if not n.is_unit() or n.hp <= 0 or not n.orders.is_empty():
			continue
		var tx := n.x - e.x
		var ty := n.y - e.y
		var rr := e.radius + n.radius
		var lim := rr + lookahead
		if absi(tx) > lim or absi(ty) > lim:
			continue
		var nd2 := Fixed.mul(tx, tx) + Fixed.mul(ty, ty)
		if nd2 == 0 or nd2 > Fixed.mul(lim, lim):
			continue
		if Fixed.mul(dx, tx) + Fixed.mul(dy, ty) <= 0:
			continue # behind us
		# Lateral offset of the blocker from our heading line: |cross|/d.
		if absi(Fixed.mul(dx, ty) - Fixed.mul(dy, tx)) >= Fixed.mul(rr, d):
			continue # we pass clear of it
		# Nearest blocker, ties to the lowest id (neighbor iteration is not
		# id-sorted, so the tie-break must be explicit).
		if best == null or nd2 < best_d2 or (nd2 == best_d2 and n.id < best.id):
			best = n
			best_d2 = nd2
	if best == null:
		return Vector2i(dx, dy)
	var bx := best.x - e.x
	var by := best.y - e.y
	if Fixed.mul(dx, by) - Fixed.mul(dy, bx) > 0:
		return Vector2i(by, -bx)
	return Vector2i(-by, bx)


## Crowd-arrival test: `e` is moving, `n` is idle and finished an order to
## the same destination (group key), and `e` is already inside its order's
## cluster radius — so packing stays tight around the goal instead of
## chaining outward.
func _arrived_neighbor(e: SimEntity, n: SimEntity) -> bool:
	if e.goal_key == -1 or e.orders.is_empty():
		return false
	var o: Dictionary = e.orders[0]
	if not n.orders.is_empty() or n.done_goal_key != o.get("group", e.goal_key):
		return false
	# Wedged behind its own arrived crowd with no progress for a second:
	# complete regardless of the cluster cap (anti-deadlock — e.g. a
	# surround slot on the far side that bodies now block).
	if e.stall >= STALL_TICKS:
		return true
	var dx: int = o["x"] - e.x
	var dy: int = o["y"] - e.y
	var cluster: int = o.get("cluster", ARRIVE_DIST)
	if absi(dx) > cluster or absi(dy) > cluster:
		return false
	return Fixed.mul(dx, dx) + Fixed.mul(dy, dy) <= Fixed.mul(cluster, cluster)


func _complete_order(e: SimEntity) -> void:
	# PATROL (design_m4.md §9.3): on reaching an endpoint, swap to the other
	# and keep going (attack-moving, re-acquiring along each leg) — the order
	# never pops.
	var o: Dictionary = e.orders[0]
	if o.get("patrol", false):
		if o["x"] == o["bx"] and o["y"] == o["by"]:
			o["x"] = o["ax"]
			o["y"] = o["ay"]
		else:
			o["x"] = o["bx"]
			o["y"] = o["by"]
		_start_order(e)
		return
	# Record the destination's group key (not the personal slot cell) so
	# crowd arrival matches across slot-mates of the same order.
	e.done_goal_key = o.get("group", e.goal_key)
	e.orders.pop_front()
	_start_order(e)


## Drop without marking arrival (unreachable / gave up).
func _drop_order(e: SimEntity) -> void:
	e.orders.pop_front()
	_start_order(e)


func _push_out_of_blocked(e: SimEntity) -> void:
	var cx := grid.cell_of(e.x)
	var cy := grid.cell_of(e.y)
	for oy in range(-1, 2):
		for ox in range(-1, 2):
			var bx := cx + ox
			var by := cy + oy
			if not grid.is_blocked(bx, by):
				continue
			var min_x := bx * SimGrid.CELL
			var min_y := by * SimGrid.CELL
			var max_x := min_x + SimGrid.CELL
			var max_y := min_y + SimGrid.CELL
			var px := clampi(e.x, min_x, max_x)
			var py := clampi(e.y, min_y, max_y)
			var dx := e.x - px
			var dy := e.y - py
			if absi(dx) >= e.radius or absi(dy) >= e.radius:
				continue
			if dx == 0 and dy == 0:
				# Center inside the cell: exit through the nearest face.
				var pens := [e.x - min_x, max_x - e.x, e.y - min_y, max_y - e.y]
				var face := pens.find(pens.min())
				match face:
					0: e.x = min_x - e.radius
					1: e.x = max_x + e.radius
					2: e.y = min_y - e.radius
					3: e.y = max_y + e.radius
				continue
			var d2 := Fixed.mul(dx, dx) + Fixed.mul(dy, dy)
			if d2 >= Fixed.mul(e.radius, e.radius):
				continue
			var d := Fixed.sqrt(d2)
			if d == 0:
				continue
			var push := e.radius - d
			e.x += dx * push / d
			e.y += dy * push / d


func _rebuild_buckets(ids: Array) -> void:
	_buckets.clear()
	for id in ids:
		var e: SimEntity = entities[id]
		if e.hp <= 0:
			continue
		if e.is_unit():
			if e.is_underground():
				continue # no collision, no targeting while burrowed (§4.8)
			_bucket_insert(Vector2i(e.x >> BUCKET_SHIFT, e.y >> BUCKET_SHIFT), id)
		else:
			# Structures span every bucket their footprint AABB overlaps.
			var x0 := (e.foot_x * SimGrid.CELL) >> BUCKET_SHIFT
			var y0 := (e.foot_y * SimGrid.CELL) >> BUCKET_SHIFT
			var x1 := ((e.foot_x + e.foot_w) * SimGrid.CELL) >> BUCKET_SHIFT
			var y1 := ((e.foot_y + e.foot_h) * SimGrid.CELL) >> BUCKET_SHIFT
			for by in range(y0, y1 + 1):
				for bx in range(x0, x1 + 1):
					_bucket_insert(Vector2i(bx, by), id)


func _bucket_insert(key: Vector2i, id: int) -> void:
	if not _buckets.has(key):
		_buckets[key] = []
	_buckets[key].append(id)


## Ids within `radius_buckets` of e's bucket; ids <= `above` excluded
## (pass 0 to get all). NOT globally sorted — iteration order is bucket
## key order, then insertion (ascending id) within a bucket. That order is
## identical on every peer, which is all determinism needs; callers that
## care about ties must tie-break explicitly (see _acquire/_steer_around).
func _bucket_neighbors(e: SimEntity, radius_buckets: int, above: int) -> Array:
	var bx := e.x >> BUCKET_SHIFT
	var by := e.y >> BUCKET_SHIFT
	var result := []
	for oy in range(-radius_buckets, radius_buckets + 1):
		for ox in range(-radius_buckets, radius_buckets + 1):
			var key := Vector2i(bx + ox, by + oy)
			if not _buckets.has(key):
				continue
			for id in _buckets[key]:
				if id > above and id != e.id:
					result.append(id)
	return result


func _length(dx: int, dy: int) -> int:
	return Fixed.sqrt(Fixed.mul(dx, dx) + Fixed.mul(dy, dy))


## Plain integer square root (not fixed-point).
func _isqrt(n: int) -> int:
	var r := 0
	while (r + 1) * (r + 1) <= n:
		r += 1
	return r


# --- combat -----------------------------------------------------------------


func _combat_system() -> void:
	for id in _sorted_ids():
		var e: SimEntity = entities[id]
		if e.hp <= 0 or e.damage <= 0:
			continue
		# Growing structures and capsules cannot fight (§4.5); neither can
		# burrowed or mid-morph units (§4.8).
		if e.kind == SimEntity.Kind.STRUCTURE \
				and e.build_state != SimEntity.BuildState.COMPLETE:
			continue
		if e.is_underground() or e.morph_ticks_left > 0:
			continue
		if e.cooldown > 0:
			e.cooldown -= 1
		var t: SimEntity = entities.get(e.target_id) if e.target_id != 0 else null
		if t != null and (t.hp <= 0 or not _can_target(e, t)
				or not _in_range(e, t, e.acquire_range, false)):
			t = null
			e.target_id = 0
		# Plain MOVE never picks fights; idle, ATTACK_MOVE, and structures do.
		# Acquisition scans are staggered across two ticks by entity id —
		# halves the dominant combat cost in big battles for at most 50 ms
		# of target-switch latency. (tick + id) parity is sim state, so
		# every peer staggers identically.
		var moving_plain: bool = not e.orders.is_empty() \
				and e.orders[0]["kind"] == SimCommand.Kind.MOVE
		if t == null and not moving_plain and (tick + e.id) & 1 == 0:
			t = _acquire(e)
			e.target_id = t.id if t != null else 0
		if t != null and e.cooldown == 0 and _in_range(e, t, e.attack_range, true):
			var dmg := e.damage
			if e.crit_base > 0 \
					and ProcRng.roll(rng, e.procs, "crit", e.crit_base, e.crit_bonus):
				dmg *= 2
			# damage x class matrix x effective damage_taken, fixed muls
			# truncating at each step (sim-visible rounding, documented in
			# design_m3.md §2.6).
			t.hp -= Fixed.to_int(Fixed.mul(
					Fixed.mul(Fixed.from_int(dmg),
							catalog.class_mul(e.attack_class, _eff_armor_class(t))),
					eff_damage_taken(t)))
			e.cooldown = e.cooldown_ticks


## Effective armor class for damage: a not-yet-COMPLETE structure presents
## `construction` (design_m4.md §4.3) so anti-construction units melt it;
## everything else uses its catalog armor class.
func _eff_armor_class(t: SimEntity) -> int:
	if _construction_armor != -1 and t.kind == SimEntity.Kind.STRUCTURE \
			and t.build_state != SimEntity.BuildState.COMPLETE:
		return _construction_armor
	return t.armor_class


## Active ATTACK_MOVE target standing in attack range (movement pauses).
func _engaged(e: SimEntity) -> bool:
	if e.target_id == 0:
		return false
	var t: SimEntity = entities.get(e.target_id)
	return t != null and t.hp > 0 and t.player != e.player \
			and _in_range(e, t, e.attack_range, true)


## Targetability rules in one place: enemies only, untargetables never
## (resources/scenery), and aerial capsules only for hits_air attackers —
## melee can't bite the sky (§4.5).
func _can_target(e: SimEntity, t: SimEntity) -> bool:
	if not t.targetable or t.player == e.player:
		return false
	if t.is_aerial() and not e.hits_air:
		return false
	if t.is_underground():
		return false
	return true


## Nearest live enemy within acquire range; ties go to the lowest id. Tactics
## (design_m4.md §9.1) bias it: focus_fire prefers a target a groupmate already
## engages; defensive won't reach past its anchor leash.
func _acquire(e: SimEntity) -> SimEntity:
	if e.tactic_flags & CatalogSchema.TacticFlag.FOCUS_FIRE:
		var ff := _focus_target(e)
		if ff != null:
			return ff
	var leashed: bool = e.stance == CatalogSchema.Stance.DEFENSIVE and e.anchor_set
	var leash: int = catalog.globals["leash_defensive"]
	var best: SimEntity = null
	var best_d2 := Fixed.mul(e.acquire_range, e.acquire_range)
	var reach := (e.acquire_range >> BUCKET_SHIFT) + 1
	for nid in _bucket_neighbors(e, reach, 0):
		var n: SimEntity = entities[nid]
		if n.hp <= 0 or not _can_target(e, n):
			continue
		if leashed and not _within_dist(e.anchor_x, e.anchor_y, n.x, n.y, leash):
			continue  # defensive: ignore threats away from the anchor
		var dx := n.x - e.x
		var dy := n.y - e.y
		var d2 := Fixed.mul(dx, dx) + Fixed.mul(dy, dy)
		# Nearest, ties to the lowest id (neighbor iteration is not
		# id-sorted, so the tie-break must be explicit).
		if d2 < best_d2 or (d2 == best_d2 and (best == null or n.id < best.id)):
			best_d2 = d2
			best = n
	return best


## Lowest-id enemy in acquire range that an allied focus-fire unit already
## targets — so a focus_fire group concentrates damage (design_m4.md §9.1).
func _focus_target(e: SimEntity) -> SimEntity:
	for id in _sorted_ids():
		var t: SimEntity = entities[id]
		if t.hp <= 0 or not _can_target(e, t):
			continue
		if not _in_range(e, t, e.acquire_range, false):
			continue
		for aid in _sorted_ids():
			var a: SimEntity = entities[aid]
			if a.id != e.id and a.is_unit() and a.hp > 0 and a.player == e.player \
					and (a.tactic_flags & CatalogSchema.TacticFlag.FOCUS_FIRE) \
					and a.target_id == t.id:
				return t
	return null


## edge_to_edge adds both radii (attack range); acquire is center-to-center.
func _in_range(e: SimEntity, t: SimEntity, r: int, edge_to_edge: bool) -> bool:
	var reach := r + e.radius + t.radius if edge_to_edge else r
	var dx := t.x - e.x
	var dy := t.y - e.y
	if absi(dx) > reach or absi(dy) > reach:
		return false
	return Fixed.mul(dx, dx) + Fixed.mul(dy, dy) <= Fixed.mul(reach, reach)


func _reap() -> void:
	for id in _sorted_ids():
		var e: SimEntity = entities[id]
		if e.hp > 0:
			continue
		if e.blocks:
			grid.unblock_rect(e.foot_x, e.foot_y, e.foot_w, e.foot_h)
		entities.erase(id)


# --- production (design_m3.md §4.7) --------------------------------------------


const TRAIN_QUEUE_MAX := 5


## Cost and bandwidth reserve are taken at queue time; CANCEL refunds both.
func _execute_train(cmd: SimCommand) -> void:
	if cmd.targets.is_empty():
		return
	var e: SimEntity = entities.get(cmd.targets[0])
	if not _functional(e) or e.player != cmd.player_id \
			or e.kind != SimEntity.Kind.STRUCTURE:
		return
	var type: int = cmd.params.get("type", -1)
	if type < 0 or type >= catalog.size() or catalog.kind_of(type) != "unit":
		return
	if type not in catalog.sim_of(e.type_key)["trains"]:
		return
	if e.train_queue.size() >= TRAIN_QUEUE_MAX:
		return
	var player: SimPlayer = players.get(cmd.player_id)
	if player == null:
		return
	var s := catalog.sim_of(type)
	if player.alloy < Fixed.from_int(s["cost_alloy"]) \
			or player.flux < Fixed.from_int(s["cost_flux"]):
		return
	var bw := bandwidth_of(cmd.player_id)
	if bw["used"] + s["bandwidth"] > bw["provided"]:
		return
	player.alloy -= Fixed.from_int(s["cost_alloy"])
	player.flux -= Fixed.from_int(s["cost_flux"])
	e.train_queue.append({"type": type, "left": s["train_time"]})


func _execute_cancel(cmd: SimCommand) -> void:
	var player: SimPlayer = players.get(cmd.player_id)
	if player == null:
		return
	# Cancel a drawn-wall plan: clears the remaining (unbuilt) queue; segments
	# already started persist as the structures they are (design_m4.md §4.4).
	if cmd.params.get("wall", false):
		for claimer in player.wall_claims:
			var cw: SimEntity = entities.get(claimer)
			if cw != null:
				cw.wall_target_cell = -1
		player.wall_cells = PackedInt32Array()
		player.wall_claims = PackedInt32Array()
		player.wall_type = -1
		return
	if cmd.targets.is_empty():
		return
	var e: SimEntity = entities.get(cmd.targets[0])
	if e == null or e.hp <= 0 or e.player != cmd.player_id:
		return
	# Cancel a structure under construction: destroy it for a partial refund
	# (the SC convention, §4.1). Workers on it free themselves next tick.
	if e.kind == SimEntity.Kind.STRUCTURE \
			and e.build_state != SimEntity.BuildState.COMPLETE:
		var s2 := catalog.sim_of(e.type_key)
		player.alloy += Fixed.from_int(s2["cost_alloy"]) / 2
		player.flux += Fixed.from_int(s2["cost_flux"]) / 2
		e.hp = 0  # reaped (unblocks its footprint) this tick
		return
	var index: int = cmd.params.get("index", -1)
	if index < 0 or index >= e.train_queue.size():
		return
	var s := catalog.sim_of(e.train_queue[index]["type"])
	player.alloy += Fixed.from_int(s["cost_alloy"])
	player.flux += Fixed.from_int(s["cost_flux"])
	e.train_queue.remove_at(index)


func _execute_set_rally(cmd: SimCommand) -> void:
	if cmd.targets.is_empty():
		return
	var e: SimEntity = entities.get(cmd.targets[0])
	if e == null or e.hp <= 0 or e.player != cmd.player_id \
			or e.kind != SimEntity.Kind.STRUCTURE:
		return
	e.rally_x = clampi(cmd.params.get("x", 0), 0, grid.world_w())
	e.rally_y = clampi(cmd.params.get("y", 0), 0, grid.world_h())


## One item builds at a time. On completion the unit spawns at the first
## free cell scanning rings outward from the footprint; if none is free,
## completion waits a tick and retries.
func _production_system() -> void:
	for id in _sorted_ids():
		var e: SimEntity = entities[id]
		if e.kind != SimEntity.Kind.STRUCTURE or not _functional(e) \
				or e.train_queue.is_empty():
			continue
		var head: Dictionary = e.train_queue[0]
		if head["left"] > 0:
			head["left"] -= 1
		if head["left"] > 0:
			continue
		var cell := _free_cell_near_rect(e.foot_x, e.foot_y, e.foot_w, e.foot_h)
		if cell == -1:
			continue # retry next tick
		var ux := grid.cell_center(cell % grid.width)
		var uy := grid.cell_center(cell / grid.width)
		var uid := spawn_unit(e.player, ux, uy, head["type"])
		e.train_queue.pop_front()
		if e.rally_x != 0 or e.rally_y != 0:
			var rally := SimCommand.new(e.player, SimCommand.Kind.MOVE)
			rally.targets = [uid]
			rally.params = {"x": e.rally_x, "y": e.rally_y}
			_order_move(rally)


## First unblocked cell on rings around a footprint rect, scanning each
## ring in a fixed order (top row, bottom row, left column, right column)
## so every peer picks the same cell. -1 if none within max_radius rings.
func _free_cell_near_rect(cx: int, cy: int, w: int, h: int,
		max_radius: int = 12) -> int:
	for r in range(1, max_radius + 1):
		var x0 := cx - r
		var x1 := cx + w - 1 + r
		var y0 := cy - r
		var y1 := cy + h - 1 + r
		for x in range(x0, x1 + 1):
			if grid.in_bounds(x, y0) and not grid.is_blocked(x, y0):
				return grid.index(x, y0)
			if grid.in_bounds(x, y1) and not grid.is_blocked(x, y1):
				return grid.index(x, y1)
		for y in range(y0 + 1, y1):
			if grid.in_bounds(x0, y) and not grid.is_blocked(x0, y):
				return grid.index(x0, y)
			if grid.in_bounds(x1, y) and not grid.is_blocked(x1, y):
				return grid.index(x1, y)
	return -1


# --- commanded abilities (design_m3.md §4.8) ------------------------------------


## One execution path for every commanded ability: validate per unit
## (ascending id), then dispatch on ability_kind. Failed checks skip that
## unit silently — commands are requests.
func _execute_ability(cmd: SimCommand) -> void:
	var ability: int = cmd.params.get("ability", -1)
	if ability < 0 or ability >= catalog.size() \
			or catalog.kind_of(ability) != "ability":
		return
	var ab := catalog.sim_of(ability)
	for e in _own_units(cmd):
		if e.is_underground() or e.morph_ticks_left > 0:
			continue
		if ability not in _abilities_of(e):
			continue
		if e.ability_cooldowns.get(ability, 0) > 0:
			continue
		match ab["ability_kind"]:
			CatalogSchema.AbilityKind.TOGGLE_MORPH:
				# No cooldown — the morph time is the cost.
				e.morph_ticks_left = ab["morph_time"]
				e.orders.clear()
				e.path = PackedInt32Array()
				e.goal_key = -1
				e.target_id = 0
			CatalogSchema.AbilityKind.BLINK:
				var tx: int = clampi(cmd.params.get("x", e.x),
						SimGrid.CELL / 2, grid.world_w() - SimGrid.CELL / 2)
				var ty: int = clampi(cmd.params.get("y", e.y),
						SimGrid.CELL / 2, grid.world_h() - SimGrid.CELL / 2)
				var dx := tx - e.x
				var dy := ty - e.y
				var r: int = ab["range"]
				if absi(dx) > r or absi(dy) > r \
						or Fixed.mul(dx, dx) + Fixed.mul(dy, dy) > Fixed.mul(r, r):
					continue
				e.underground_ticks_left = ab["travel_time"]
				e.surface_x = tx
				e.surface_y = ty
				e.orders.clear()
				e.path = PackedInt32Array()
				e.goal_key = -1
				e.target_id = 0
			_:
				pass # auras are passive; build runs through BUILD (§4.5)


## Per-tick unit status: ability cooldowns, morph transitions, and
## underground travel/surfacing.
func _status_system() -> void:
	for id in _sorted_ids():
		var e: SimEntity = entities[id]
		if not e.is_unit() or e.hp <= 0:
			continue
		for key in e.ability_cooldowns.keys():
			e.ability_cooldowns[key] -= 1
			if e.ability_cooldowns[key] <= 0:
				e.ability_cooldowns.erase(key)
		if e.morph_ticks_left > 0:
			e.morph_ticks_left -= 1
			if e.morph_ticks_left == 0:
				e.morphed = not e.morphed
				_apply_morph_stats(e)
		if e.is_underground():
			e.underground_ticks_left -= 1
			if e.underground_ticks_left == 0:
				_surface(e)


## Apply the morphed form's stat overrides, or restore catalog base stats
## on unmorph. Overrides are static catalog values, so apply/restore is
## deterministic with no extra state.
func _apply_morph_stats(e: SimEntity) -> void:
	var base := catalog.sim_of(e.type_key)
	var overrides := {}
	for ak in _abilities_of(e):
		var ab := catalog.sim_of(ak)
		if ab["ability_kind"] == CatalogSchema.AbilityKind.TOGGLE_MORPH:
			overrides = ab["morphed"]
			break
	var source := overrides if e.morphed else base
	for field: String in overrides:
		var v: Variant = source[field] if source.has(field) else base[field]
		match field:
			"speed":
				e.step = int(v) / TICK_RATE
			"damage":
				e.damage = v
			"attack_range":
				e.attack_range = v
			"acquire_range":
				e.acquire_range = v
			"cooldown":
				e.cooldown_ticks = v
			"hits_air":
				e.hits_air = v
			"radius":
				e.radius = v
			"sight":
				e.sight = v
			"armor_class":
				e.armor_class = v
			"attack_class":
				e.attack_class = v
			"hp", "crit_base", "crit_bonus":
				pass # not morphable: hp swings mid-fight are a balance trap
			_:
				pass


## Surface at the nearest free cell to the burrow target (the same
## deterministic ring scan production uses); the per-entity cooldown
## starts now (§4.8).
func _surface(e: SimEntity) -> void:
	var cell := grid.nearest_free_cell(
			clampi(grid.cell_of(e.surface_x), 0, grid.width - 1),
			clampi(grid.cell_of(e.surface_y), 0, grid.height - 1))
	if cell == -1:
		e.underground_ticks_left = 1 # nowhere to surface; try again next tick
		return
	e.x = grid.cell_center(cell % grid.width)
	e.y = grid.cell_center(cell / grid.width)
	e.surface_x = 0
	e.surface_y = 0
	for ak in _abilities_of(e):
		var ab := catalog.sim_of(ak)
		if ab["ability_kind"] == CatalogSchema.AbilityKind.BLINK \
				and ab["cooldown_time"] > 0:
			e.ability_cooldowns[ak] = ab["cooldown_time"]
			break


# --- unit AI: stances, tactics, patrol (design_m4.md §9) ----------------------


## A unit is "ranged" for the skirmish/kite rule (design_m4.md §9.1).
const RANGED_THRESHOLD := Fixed.ONE * 2


func _execute_set_tactic(cmd: SimCommand) -> void:
	var has_stance: bool = cmd.params.has("stance")
	var stance: int = cmd.params.get("stance", 0)
	var has_flags: bool = cmd.params.has("flags")
	var flags: int = cmd.params.get("flags", 0)
	for e in _own_units(cmd):
		if has_stance:
			e.stance = stance
			# Defensive plants an anchor at the unit's current spot; other
			# stances don't lean on one (design_m4.md §9.1).
			if stance == CatalogSchema.Stance.DEFENSIVE:
				e.anchor_x = e.x
				e.anchor_y = e.y
				e.anchor_set = true
			else:
				e.anchor_set = false
		if has_flags:
			e.tactic_flags = flags


## PATROL (design_m4.md §9.3): two endpoints (the unit's position now and the
## target); the unit attack-moves between them, swapping on arrival.
func _execute_patrol(cmd: SimCommand) -> void:
	var units := _own_units(cmd)
	for e in units:
		e.build_target = 0
		e.wall_target_cell = -1
		var bx: int = clampi(cmd.params.get("x", e.x),
				SimGrid.CELL / 2, grid.world_w() - SimGrid.CELL / 2)
		var by: int = clampi(cmd.params.get("y", e.y),
				SimGrid.CELL / 2, grid.world_h() - SimGrid.CELL / 2)
		var gcx := clampi(grid.cell_of(bx), 0, grid.width - 1)
		var gcy := clampi(grid.cell_of(by), 0, grid.height - 1)
		var order := {
			"kind": SimCommand.Kind.ATTACK_MOVE,
			"x": bx, "y": by, "small": true,
			"group": grid.index(gcx, gcy),
			"cluster": ARRIVE_DIST + e.radius * 2,
			"patrol": true, "ax": e.x, "ay": e.y, "bx": bx, "by": by,
		}
		e.orders.clear()
		e.orders.append(order)
		e.target_id = 0
		_start_order(e)


## Stance behavior for idle combat units (design_m4.md §9.1): reckless chases
## its acquired target, defensive engages only within leash of its anchor and
## returns when pulled off, skirmish kites at min range. Balanced (and units
## under a player order, or busy with economy) keep the M3 behavior. Runs
## after combat so it reacts to this tick's acquisition.
func _stance_system() -> void:
	for id in _sorted_ids():
		var e: SimEntity = entities[id]
		if not e.is_unit() or e.hp <= 0 or e.damage <= 0:
			continue
		if e.is_underground() or e.morph_ticks_left > 0:
			continue
		if not e.orders.is_empty():
			continue  # a player order is driving it
		if e.build_target != 0 or _is_worker(e) \
				or e.harvest_state != SimEntity.HarvestState.IDLE:
			continue  # busy with economy
		if e.tactic_flags & CatalogSchema.TacticFlag.HOLD_POSITION:
			continue  # planted: fire only at in-range targets
		var t: SimEntity = entities.get(e.target_id)
		var has_target := t != null and t.hp > 0 and t.player != e.player
		match e.stance:
			CatalogSchema.Stance.RECKLESS:
				if has_target and not _in_range(e, t, e.attack_range, true):
					_step_toward(e, t.x, t.y)
			CatalogSchema.Stance.DEFENSIVE:
				_stance_defensive(e, t, has_target)
			CatalogSchema.Stance.SKIRMISH:
				if has_target and e.attack_range > RANGED_THRESHOLD:
					var kmin: int = catalog.globals["kite_min_distance"]
					var dx := t.x - e.x
					var dy := t.y - e.y
					if Fixed.mul(dx, dx) + Fixed.mul(dy, dy) < Fixed.mul(kmin, kmin):
						_step_away(e, t.x, t.y)  # too close: back off, keep firing
			_:
				pass  # BALANCED == M3


func _stance_defensive(e: SimEntity, t: SimEntity, has_target: bool) -> void:
	var leash: int = catalog.globals["leash_defensive"]
	var ax := e.anchor_x if e.anchor_set else e.x
	var ay := e.anchor_y if e.anchor_set else e.y
	if has_target and _within_dist(ax, ay, t.x, t.y, leash):
		if not _in_range(e, t, e.attack_range, true):
			_step_toward(e, t.x, t.y)  # close on a threat near the anchor
		return
	# No engageable threat: walk back to the anchor if pulled off it.
	if e.anchor_set and not _within_dist(e.x, e.y, ax, ay, ARRIVE_DIST):
		_step_toward(e, ax, ay)


## Direct fixed-point step toward a point (no pathfinding — stances are a thin
## v1 layer, §9), kept on the map and out of blocked cells.
func _step_toward(e: SimEntity, tx: int, ty: int) -> void:
	var dx := tx - e.x
	var dy := ty - e.y
	var d := _length(dx, dy)
	if d == 0:
		return
	if d <= e.step:
		e.x = tx
		e.y = ty
	else:
		e.x += dx * e.step / d
		e.y += dy * e.step / d
	e.x = clampi(e.x, e.radius, grid.world_w() - e.radius)
	e.y = clampi(e.y, e.radius, grid.world_h() - e.radius)
	_push_out_of_blocked(e)


func _step_away(e: SimEntity, tx: int, ty: int) -> void:
	var dx := e.x - tx
	var dy := e.y - ty
	var d := _length(dx, dy)
	if d == 0:
		dx = Fixed.ONE
		d = Fixed.ONE
	e.x += dx * e.step / d
	e.y += dy * e.step / d
	e.x = clampi(e.x, e.radius, grid.world_w() - e.radius)
	e.y = clampi(e.y, e.radius, grid.world_h() - e.radius)
	_push_out_of_blocked(e)


func _within_dist(ax: int, ay: int, bx: int, by: int, r: int) -> bool:
	var dx := bx - ax
	var dy := by - ay
	if absi(dx) > r or absi(dy) > r:
		return false
	return Fixed.mul(dx, dx) + Fixed.mul(dy, dy) <= Fixed.mul(r, r)


# --- nanomachine economy (design_m3.md §4.6) ----------------------------------


## Per-stronghold income recorded for the Economy tab (derived, never
## hashed): stronghold id -> {"alloy": fixed/tick, "flux": fixed/tick,
## "assist_used": int, "idle": int}. The UI's "allocation idle: no
## deposits in range" warning reads the gap between allocation and this.
var income: Dictionary = {}


func _economy_system() -> void:
	income.clear()
	for id in _sorted_ids():
		var e: SimEntity = entities[id]
		if e.kind != SimEntity.Kind.STRUCTURE or not _functional(e):
			continue
		var s := catalog.sim_of(e.type_key)
		var pool: int = s["nano_pool"]
		if pool <= 0:
			continue
		var player: SimPlayer = players.get(e.player)
		if player == null:
			continue
		var r := _territory_radius(e)
		var alloc := e.nano_alloc
		# Repair/build runs first so assist nanos that find no work this tick
		# fall back to harvesting instead of sitting idle (design intent:
		# "nothing to repair or build -> back to mining").
		var assist_used := _assist(e, r, alloc[2])
		var idle_assist: int = alloc[2] - assist_used
		var mine_alloy: int = alloc[0]
		var mine_flux: int = alloc[1]
		if idle_assist > 0:
			# Returned nanos follow the alloy:flux split already chosen; with
			# no resource share expressed they divide evenly.
			var base: int = alloc[0] + alloc[1]
			var extra_alloy: int = idle_assist / 2 if base == 0 \
					else idle_assist * alloc[0] / base
			mine_alloy += extra_alloy
			mine_flux += idle_assist - extra_alloy
		var mined_alloy := _mine(e, player, r, CatalogSchema.ResourceKind.ALLOY,
				catalog.globals["alloy_rate"], mine_alloy)
		var mined_flux := _mine(e, player, r, CatalogSchema.ResourceKind.FLUX,
				catalog.globals["flux_rate"], mine_flux)
		income[id] = {
			"alloy": mined_alloy, "flux": mined_flux,
			"assist_used": assist_used, "idle_assist": idle_assist,
			"idle": pool - alloc[0] - alloc[1] - alloc[2],
		}


## The radius of this structure's own territory aura (its reach for
## mining/assist is its own circle, not the union — §4.3), 0 if none.
func _territory_radius(e: SimEntity) -> int:
	for ak in _abilities_of(e):
		var ab := catalog.sim_of(ak)
		if ab["ability_kind"] == CatalogSchema.AbilityKind.AURA \
				and "territory" in ab["flags"]:
			return ab["radius"]
	return 0


## Extract up to rate x nanos this tick from eligible sources inside the
## stronghold's circle, in ascending node id, each capped by its
## throughput. Returns the amount mined (fixed). For ALLOY the sources
## are deposit nodes; for FLUX they are this player's COMPLETE siphons
## (drawing from their linked vents).
func _mine(sh: SimEntity, player: SimPlayer, r: int, res_kind: int,
		rate: int, nanos: int) -> int:
	if nanos <= 0 or r <= 0:
		return 0
	var demand := (rate / TICK_RATE) * nanos
	var mined := 0
	for id in _sorted_ids():
		if demand <= 0:
			break
		var node: SimEntity = null
		if res_kind == CatalogSchema.ResourceKind.ALLOY:
			var n: SimEntity = entities[id]
			if not n.is_resource() or n.resource_kind != res_kind:
				continue
			if not _circle_covers(sh.x, sh.y, r, n.x, n.y):
				continue
			node = n
		else:
			var siphon: SimEntity = entities[id]
			if siphon.kind != SimEntity.Kind.STRUCTURE or siphon.vent_id == 0 \
					or siphon.player != sh.player or not _functional(siphon):
				continue
			if not _circle_covers(sh.x, sh.y, r, siphon.x, siphon.y):
				continue
			node = entities.get(siphon.vent_id)
			if node == null:
				continue
		if node.amount <= 0:
			continue
		var cap: int = catalog.sim_of(node.type_key)["throughput"] / TICK_RATE
		var draw := mini(demand, mini(cap, node.amount))
		node.amount -= draw
		demand -= draw
		mined += draw
	if res_kind == CatalogSchema.ResourceKind.ALLOY:
		player.alloy += mined
	else:
		player.flux += mined
	return mined


## Distribute assist nanos: construction before repair, fill one structure
## then the next, ascending id (§4.6). Construction grants assist_bonus
## (consumed by the structures phase this tick); repair feeds heal_acc.
## Returns how many nanos found work.
func _assist(sh: SimEntity, r: int, nanos: int) -> int:
	if nanos <= 0 or r <= 0:
		return 0
	var growing: Array[SimEntity] = []
	var damaged: Array[SimEntity] = []
	for id in _sorted_ids():
		var e: SimEntity = entities[id]
		if e.kind != SimEntity.Kind.STRUCTURE or e.hp <= 0 or e.player != sh.player:
			continue
		if not _circle_covers(sh.x, sh.y, r, e.x, e.y):
			continue
		if e.build_state == SimEntity.BuildState.GROWING:
			growing.append(e)
		elif e.build_state == SimEntity.BuildState.COMPLETE and e.hp < e.max_hp:
			damaged.append(e)
	var assist_rate: int = catalog.globals["assist_rate"]
	var repair_per_tick: int = catalog.globals["repair_rate"] / TICK_RATE
	var used := 0
	var gi := 0
	var di := 0
	for i in nanos:
		# A growing structure absorbs bonus until natural progress (ONE)
		# plus granted bonus covers what's left.
		while gi < growing.size() \
				and growing[gi].build_ticks_left - Fixed.ONE - growing[gi].assist_bonus <= 0:
			gi += 1
		if gi < growing.size():
			growing[gi].assist_bonus += assist_rate
			used += 1
			continue
		while di < damaged.size() \
				and damaged[di].hp + Fixed.to_int(damaged[di].heal_acc) >= damaged[di].max_hp:
			di += 1
		if di < damaged.size():
			damaged[di].heal_acc += repair_per_tick
			used += 1
	return used


# --- worker harvest economy (design_m4.md §3) ---------------------------------
## The Rebel mirror of nanomachines: a loop of physical bodies. Dials set a
## target distribution (§3.2); the sim reconciles tasks toward it every tick,
## sim-side so the approximation is identical on every lockstep peer. All
## fixed-point, ascending-id, hashed.


const HARVEST_REACH := SimGrid.CELL * 2  # extra slack on top of radii (fixed)


func _worker_economy_system() -> void:
	var pids := players.keys()
	pids.sort()
	for pid in pids:
		_reconcile_economy(pid)
	# Harvest pass: ascending worker id, so per-node throughput sharing is
	# ascending-id by construction. budget: node id -> remaining fixed/tick.
	var budget := {}
	for id in _sorted_ids():
		var w: SimEntity = entities[id]
		if not _is_worker(w) or w.hp <= 0 or w.build_target != 0:
			continue
		_harvest_tick(w, budget)


## Turn a player's dials into target task counts and reconcile assignments
## (§3.2): build reserve, then the harvest pool split by alloy_flux_ratio.
## Also auto-replaces losses toward worker_target.
func _reconcile_economy(pid: int) -> void:
	var p: SimPlayer = players.get(pid)
	if p == null:
		return
	var workers: Array[int] = []
	for id in _sorted_ids():
		var e: SimEntity = entities[id]
		if e.hp > 0 and e.player == pid and _is_worker(e):
			workers.append(id)
	# Auto-replace: train toward worker_target counting live + queued (§3.2).
	if p.worker_target > workers.size() + _queued_workers(pid):
		_queue_replacement_worker(pid)
	var n := workers.size()
	if n == 0:
		return
	var reserve := clampi(_scale_count(n, p.build_mine_ratio), 0, n)
	var pool := n - reserve
	var desired_alloy := clampi(_scale_count(pool, p.alloy_flux_ratio), 0, pool)
	var qa := desired_alloy
	var qf := pool - desired_alloy
	# Assign by ascending id: lowest ids fill alloy then flux, the rest are
	# build reserve. Stable while counts hold; surplus sheds from the high
	# ids (the design's "take the highest-id worker" reduces to this).
	for wid in workers:
		var w: SimEntity = entities[wid]
		if qa > 0:
			w.harvest_role = 1
			qa -= 1
		elif qf > 0:
			w.harvest_role = 2
			qf -= 1
		else:
			w.harvest_role = 0  # build reserve / idle near base


## round_half_up(n * ratio) for a fixed ratio in [0,1].
func _scale_count(n: int, ratio_fixed: int) -> int:
	return (n * ratio_fixed + Fixed.HALF) >> Fixed.SHIFT


func _is_worker(e: SimEntity) -> bool:
	return e.is_unit() and catalog.sim_of(e.type_key)["carry_capacity"] > 0


func _queued_workers(pid: int) -> int:
	var count := 0
	for id in entities:
		var e: SimEntity = entities[id]
		if e.player != pid or e.kind != SimEntity.Kind.STRUCTURE:
			continue
		for q: Dictionary in e.train_queue:
			if catalog.sim_of(q["type"])["carry_capacity"] > 0:
				count += 1
	return count


## A trainable worker unit type for the player (lowest type_key), or -1.
func _worker_type_for(pid: int) -> int:
	for type: int in trainable_units(pid):
		if catalog.sim_of(type)["carry_capacity"] > 0:
			return type
	return -1


## Queue one replacement worker at the shortest-queue eligible structure;
## a no-op (silently) if unaffordable or Crew-capped — the normal TRAIN
## reservation path does the checks.
func _queue_replacement_worker(pid: int) -> void:
	var wt := _worker_type_for(pid)
	if wt < 0:
		return
	var st := train_structure_for(pid, wt)
	if st == 0:
		return
	var c := SimCommand.new(pid, SimCommand.Kind.TRAIN)
	c.targets = [st]
	c.params = {"type": wt}
	_execute_train(c)


## Advance one worker's harvest state machine (§3.1).
func _harvest_tick(w: SimEntity, budget: Dictionary) -> void:
	match w.harvest_state:
		SimEntity.HarvestState.IDLE:
			if w.harvest_role == 0:
				return  # build reserve waits near base (drawn by §4)
			var src := _pick_source(w, w.harvest_role)
			if src == 0:
				return
			w.assigned_source = src
			w.harvest_state = SimEntity.HarvestState.TO_SOURCE
			_move_to_entity(w, entities[src])
		SimEntity.HarvestState.TO_SOURCE:
			var src: SimEntity = entities.get(w.assigned_source)
			if not _valid_source(src):
				w.assigned_source = 0
				w.harvest_state = SimEntity.HarvestState.IDLE
				return
			# Role changed under us (dials moved) — drop and re-pick.
			if not _source_matches_role(src, w.harvest_role):
				w.assigned_source = 0
				w.harvest_state = SimEntity.HarvestState.IDLE
				return
			if _within_reach(w, src):
				w.harvest_state = SimEntity.HarvestState.HARVESTING
			elif w.orders.is_empty():
				_move_to_entity(w, src)  # path dropped/stalled — re-issue
		SimEntity.HarvestState.HARVESTING:
			var src: SimEntity = entities.get(w.assigned_source)
			if not _valid_source(src):
				w.harvest_state = SimEntity.HarvestState.TO_DEPOT if w.carry > 0 \
						else SimEntity.HarvestState.IDLE
				if w.carry <= 0:
					w.assigned_source = 0
				return
			_harvest_draw(w, src, budget)
			if w.carry >= _carry_cap_for(w, src):
				w.harvest_state = SimEntity.HarvestState.TO_DEPOT
		SimEntity.HarvestState.TO_DEPOT:
			if w.carry <= 0:
				w.harvest_state = SimEntity.HarvestState.IDLE
				return
			var depot := _nearest_depot(w)
			if depot == 0:
				return  # nowhere to drop off; hold the carry
			var d: SimEntity = entities[depot]
			if _within_reach(w, d):
				w.harvest_state = SimEntity.HarvestState.DEPOSITING
			elif w.orders.is_empty():
				_move_to_entity(w, d)
		SimEntity.HarvestState.DEPOSITING:
			var p: SimPlayer = players.get(w.player)
			if p != null and w.carry_kind != -1:
				if w.carry_kind == CatalogSchema.ResourceKind.ALLOY:
					p.alloy += w.carry
				else:
					p.flux += w.carry
			w.carry = 0
			w.carry_kind = -1
			w.harvest_state = SimEntity.HarvestState.IDLE  # re-task by role next tick


## A harvestable source still worth visiting: a non-empty Alloy deposit, a
## non-empty raw Flux vent with no siphon on it, or a COMPLETE own Refinery
## with at least one non-empty linked vent.
func _valid_source(src: SimEntity) -> bool:
	if src == null or src.hp <= 0:
		return false
	if src.is_resource():
		if src.amount <= 0:
			return false
		if src.resource_kind == CatalogSchema.ResourceKind.FLUX \
				and _siphon_on(src.id) != 0:
			return false
		return true
	if src.kind == SimEntity.Kind.STRUCTURE \
			and catalog.sim_of(src.type_key).get("is_refinery", false) \
			and src.build_state == SimEntity.BuildState.COMPLETE:
		for vid in src.linked_vents:
			var v: SimEntity = entities.get(vid)
			if v != null and v.amount > 0:
				return true
	return false


## ALLOY=1, FLUX=2, NONE=0 for a candidate source entity.
func _role_of_source(src: SimEntity) -> int:
	if src == null:
		return 0
	if src.is_resource():
		if src.resource_kind == CatalogSchema.ResourceKind.ALLOY:
			return 1
		if src.resource_kind == CatalogSchema.ResourceKind.FLUX:
			return 2
	elif catalog.sim_of(src.type_key).get("is_refinery", false):
		return 2
	return 0


func _source_matches_role(src: SimEntity, role: int) -> bool:
	return _role_of_source(src) == role


## Nearest valid source for the role (path-agnostic center distance, ties to
## lowest id). FLUX prefers a Refinery over a raw vent when one is available
## (§3.1). Returns entity id or 0.
func _pick_source(w: SimEntity, role: int) -> int:
	var best := 0
	var best_d2 := 0x7FFFFFFFFFFFFFF
	if role == 2:
		# Prefer refineries: scan them first; only fall back to raw vents if
		# none has flux available.
		for id in _sorted_ids():
			var e: SimEntity = entities[id]
			if e.kind == SimEntity.Kind.STRUCTURE and e.player == w.player \
					and catalog.sim_of(e.type_key).get("is_refinery", false) \
					and _valid_source(e):
				var d2 := _entity_dist2(w, e)
				if d2 < best_d2:
					best_d2 = d2
					best = id
		if best != 0:
			return best
	for id in _sorted_ids():
		var e: SimEntity = entities[id]
		if not e.is_resource():
			continue
		if role == 1 and e.resource_kind != CatalogSchema.ResourceKind.ALLOY:
			continue
		if role == 2 and e.resource_kind != CatalogSchema.ResourceKind.FLUX:
			continue
		if not _valid_source(e):
			continue
		var d2 := _entity_dist2(w, e)
		if d2 < best_d2:
			best_d2 = d2
			best = id
	return best


## Nearest COMPLETE is_depot structure of the worker's player, ties to lowest
## id (§3.1). 0 if the player has no depot.
func _nearest_depot(w: SimEntity) -> int:
	var best := 0
	var best_d2 := 0x7FFFFFFFFFFFFFF
	for id in _sorted_ids():
		var e: SimEntity = entities[id]
		if e.kind == SimEntity.Kind.STRUCTURE and e.player == w.player \
				and _functional(e) and catalog.sim_of(e.type_key).get("is_depot", false):
			var d2 := _entity_dist2(w, e)
			if d2 < best_d2:
				best_d2 = d2
				best = id
	return best


func _entity_dist2(a: SimEntity, b: SimEntity) -> int:
	var dx := b.x - a.x
	var dy := b.y - a.y
	return Fixed.mul(dx, dx) + Fixed.mul(dy, dy)


## Within harvesting/deposit reach: center distance <= both radii + slack.
func _within_reach(w: SimEntity, t: SimEntity) -> bool:
	var reach := w.radius + t.radius + HARVEST_REACH
	var dx := t.x - w.x
	var dy := t.y - w.y
	if absi(dx) > reach or absi(dy) > reach:
		return false
	return Fixed.mul(dx, dx) + Fixed.mul(dy, dy) <= Fixed.mul(reach, reach)


## Effective carry cap for this source (fixed): full capacity at a deposit
## or Refinery; the small raw_flux_carry fraction at a raw Flux vent (§3.1).
func _carry_cap_for(w: SimEntity, src: SimEntity) -> int:
	var cap := Fixed.from_int(catalog.sim_of(w.type_key)["carry_capacity"])
	if _is_raw_vent(src):
		return Fixed.mul(cap, catalog.globals["raw_flux_carry"])
	return cap


func _is_raw_vent(src: SimEntity) -> bool:
	return src.is_resource() \
			and src.resource_kind == CatalogSchema.ResourceKind.FLUX


## Per-tick harvest rate (fixed): the unit's harvest_rate (or global default)
## divided into ticks, throttled to raw_flux_rate at a raw vent (§3.1).
func _harvest_rate_for(w: SimEntity, src: SimEntity) -> int:
	var rate: int = catalog.sim_of(w.type_key)["harvest_rate"]
	if rate <= 0:
		rate = catalog.globals["harvest_rate"]
	var per_tick := rate / TICK_RATE
	if _is_raw_vent(src):
		per_tick = Fixed.mul(per_tick, catalog.globals["raw_flux_rate"])
	return per_tick


## Accrue carry this tick, drawing the node amount down (capped by the
## node's per-tick throughput budget, shared ascending-id). A Refinery draws
## across its linked vents in ascending id.
func _harvest_draw(w: SimEntity, src: SimEntity, budget: Dictionary) -> void:
	var remaining_cap := _carry_cap_for(w, src) - w.carry
	if remaining_cap <= 0:
		return
	var demand := mini(_harvest_rate_for(w, src), remaining_cap)
	if demand <= 0:
		return
	var kind: int
	var drawn := 0
	if src.is_resource():
		kind = src.resource_kind
		drawn = _draw_node(src, demand, budget)
	else:
		# Refinery: full rate, pulled live from its linked vents.
		kind = CatalogSchema.ResourceKind.FLUX
		for vid in src.linked_vents:
			if demand <= 0:
				break
			var v: SimEntity = entities.get(vid)
			if v == null or v.amount <= 0:
				continue
			var got := _draw_node(v, demand, budget)
			drawn += got
			demand -= got
	if drawn <= 0:
		return
	w.carry += drawn
	if w.carry_kind == -1:
		w.carry_kind = kind


## Draw up to `demand` from one node this tick, respecting its throughput
## budget and remaining amount. Decrements both; returns the amount drawn.
func _draw_node(node: SimEntity, demand: int, budget: Dictionary) -> int:
	var b: int = budget.get(node.id, -1)
	if b == -1:
		b = catalog.sim_of(node.type_key)["throughput"] / TICK_RATE
	var draw := mini(demand, mini(b, node.amount))
	if draw <= 0:
		budget[node.id] = b
		return 0
	node.amount -= draw
	budget[node.id] = b - draw
	return draw


## Order a single worker to walk adjacent to a (blocked) source/depot — the
## move resolves to the nearest free cell, the surround-slot behavior of a
## one-unit order.
func _move_to_entity(w: SimEntity, t: SimEntity) -> void:
	var c := SimCommand.new(w.player, SimCommand.Kind.MOVE)
	c.targets = [w.id]
	c.params = {"x": t.x, "y": t.y, "internal": true}
	_order_move(c)


# --- MINE / SET_ECONOMY (design_m4.md §3.2, §12) ------------------------------


## Manual harvest order: assign workers to a node and nudge the dials toward
## that resource (no per-unit pin — the dials are the whole truth, §3.2).
func _execute_mine(cmd: SimCommand) -> void:
	var node: SimEntity = entities.get(cmd.params.get("node", 0))
	var role := _role_of_source(node)
	if role == 0:
		return
	var n := 0
	for w in _own_units(cmd):
		if not _is_worker(w):
			continue
		w.assigned_source = node.id
		w.harvest_role = role
		if w.carry > 0:
			w.harvest_state = SimEntity.HarvestState.TO_DEPOT
		else:
			w.harvest_state = SimEntity.HarvestState.TO_SOURCE
			_move_to_entity(w, node)
		n += 1
	if n > 0:
		_nudge_alloy_flux(cmd.player_id, role, n)


## Bias alloy_flux_ratio toward the manually-ordered resource by the ordered
## workers' share of the fleet (§3.2). How far is a tuning question (§18);
## this is the simple share-proportional nudge.
func _nudge_alloy_flux(pid: int, role: int, n: int) -> void:
	var p: SimPlayer = players.get(pid)
	if p == null:
		return
	var total := 0
	for id in entities:
		var e: SimEntity = entities[id]
		if e.hp > 0 and e.player == pid and _is_worker(e):
			total += 1
	if total <= 0:
		return
	var share := Fixed.div(Fixed.from_int(n), Fixed.from_int(total))
	if role == 1:
		p.alloy_flux_ratio = mini(Fixed.ONE, p.alloy_flux_ratio + share)
	else:
		p.alloy_flux_ratio = maxi(0, p.alloy_flux_ratio - share)


func _execute_set_economy(cmd: SimCommand) -> void:
	var p: SimPlayer = players.get(cmd.player_id)
	if p == null:
		return
	p.worker_target = maxi(0, cmd.params.get("worker_target", p.worker_target))
	p.alloy_flux_ratio = clampi(cmd.params.get("alloy_flux_ratio",
			p.alloy_flux_ratio), 0, Fixed.ONE)
	p.build_mine_ratio = clampi(cmd.params.get("build_mine_ratio",
			p.build_mine_ratio), 0, Fixed.ONE)
	p.auto_repair = cmd.params.get("auto_repair", p.auto_repair)


# --- worker build + repair (design_m4.md §4) ----------------------------------


## Manual repair order: send workers to heal a damaged own COMPLETE
## structure. Piggybacks on the build path (a worker on a damaged structure
## heals instead of progressing construction, §4.2).
func _execute_repair(cmd: SimCommand) -> void:
	var t: SimEntity = entities.get(cmd.params.get("target", 0))
	if t == null or t.player != cmd.player_id \
			or t.kind != SimEntity.Kind.STRUCTURE:
		return
	for w in _own_units(cmd):
		if not _is_worker(w):
			continue
		w.build_target = t.id
		w.harvest_state = SimEntity.HarvestState.IDLE
		w.assigned_source = 0
		w.orders.clear()
		_move_to_entity(w, t)


## Workers raise the structures and walls they're committed to: walk to the
## site, then (on site) contribute build_rate / repair. Multiple builders on
## one site accelerate it for a per-tick resource drain (the WC3 model, §4.1).
func _worker_build_system() -> void:
	_wall_system()
	var groups := {}  # target id -> Array[SimEntity] builders on site, ascending id
	for id in _sorted_ids():
		var w: SimEntity = entities[id]
		if not w.is_unit() or w.hp <= 0 or w.build_target == 0:
			continue
		var t: SimEntity = entities.get(w.build_target)
		if not _valid_build_target(t, w):
			w.build_target = 0
			continue
		if _within_reach(w, t):
			w.orders.clear()  # plant on site, immobile while building
			if not groups.has(t.id):
				groups[t.id] = []
			groups[t.id].append(w)
		elif w.orders.is_empty():
			_move_to_entity(w, t)  # walk to / return to the site
	var max_builders: int = catalog.globals["max_builders"]
	var accel: int = catalog.globals["accel_cost_rate"] / TICK_RATE
	for tid in groups:
		var t: SimEntity = entities[tid]
		var p: SimPlayer = players.get(t.player)
		var builders: Array = groups[tid]
		for i in builders.size():
			if i >= max_builders:
				break  # beyond the cap: extra workers idle on site
			# The first builder is free (the cost already paid for it); each
			# extra drains accel_cost_rate and stops the instant funds run out.
			if i > 0:
				if p == null or p.alloy < accel:
					continue
				p.alloy -= accel
			_apply_builder(builders[i], t)


## A worker's build target is still worth working: an own GROWING structure,
## or an own COMPLETE structure that is damaged (repair). Otherwise the
## worker is freed.
func _valid_build_target(t: SimEntity, w: SimEntity) -> bool:
	if t == null or t.hp <= 0 or t.player != w.player \
			or t.kind != SimEntity.Kind.STRUCTURE:
		return false
	if t.build_state == SimEntity.BuildState.GROWING:
		return true
	return t.build_state == SimEntity.BuildState.COMPLETE and t.hp < t.max_hp


## One on-site builder's contribution this tick: construction progress to a
## GROWING structure (via assist_bonus, consumed by the structures phase),
## or repair to a damaged COMPLETE one.
func _apply_builder(w: SimEntity, t: SimEntity) -> void:
	if t.build_state == SimEntity.BuildState.GROWING:
		t.assist_bonus += _build_rate_of(w)
	elif t.hp < t.max_hp:
		t.heal_acc += _repair_rate_of(w)


func _build_rate_of(w: SimEntity) -> int:
	var rate: int = catalog.sim_of(w.type_key)["build_rate"]
	if rate <= 0:
		rate = catalog.globals["build_rate"]
	return rate / TICK_RATE


func _repair_rate_of(w: SimEntity) -> int:
	var rate: int = catalog.sim_of(w.type_key)["repair_rate"]
	if rate <= 0:
		rate = catalog.globals["repair_rate"]
	return rate / TICK_RATE


# --- drawn walls (design_m4.md §4.4) ------------------------------------------


## Install a per-player wall plan from a drawn stroke: an ordered queue of
## pending segment cells. Pending segments block nothing and cost nothing
## until a worker starts one, so a half-drawn plan never walls you in.
func _execute_build_wall(cmd: SimCommand) -> void:
	var p: SimPlayer = players.get(cmd.player_id)
	if p == null:
		return
	var type: int = cmd.params.get("type", -1)
	if type < 0 or type >= catalog.size() or catalog.kind_of(type) != "structure":
		return
	var cells: Array = cmd.params.get("cells", [])
	if cells.is_empty():
		return
	p.wall_type = type
	for c: int in cells:
		var cx := c % grid.width
		var cy := c / grid.width
		if grid.in_bounds(cx, cy):
			p.wall_cells.append(c)
			p.wall_claims.append(0)


## Drain each player's wall plan: assign free workers to the next unclaimed
## pending cells, and when a claiming worker reaches its cell, start the
## segment there (spawn GROWING, charge it then, hand it to the build path).
func _wall_system() -> void:
	var pids := players.keys()
	pids.sort()
	for pid in pids:
		var p: SimPlayer = players.get(pid)
		if p == null or p.wall_cells.is_empty() or p.wall_type < 0:
			continue
		var kept_cells := PackedInt32Array()
		var kept_claims := PackedInt32Array()
		for i in p.wall_cells.size():
			var cell: int = p.wall_cells[i]
			var claimer: int = p.wall_claims[i]
			var w: SimEntity = entities.get(claimer) if claimer != 0 else null
			if w == null or not w.is_unit() or w.hp <= 0 \
					or w.wall_target_cell != cell:
				claimer = 0
				w = null
			if w == null:
				var pick := _nearest_available_builder(pid, cell)
				if pick != null:
					claimer = pick.id
					pick.wall_target_cell = cell
					_move_to_cell(pick, cell)
					w = pick
			if w != null and _within_cell_reach(w, cell) \
					and not grid.is_blocked(cell % grid.width, cell / grid.width):
				# Start the segment: spawn it GROWING+frozen, charge now.
				var seg := _spawn_structure_entity(pid, cell % grid.width,
						cell / grid.width, p.wall_type, false, 0)
				seg.needs_builder = true
				p.alloy -= Fixed.from_int(catalog.globals["wall_cost_alloy"])
				w.build_target = seg.id
				w.wall_target_cell = -1
				continue  # drop this cell from the pending plan
			kept_cells.append(cell)
			kept_claims.append(claimer)
		p.wall_cells = kept_cells
		p.wall_claims = kept_claims
		if p.wall_cells.is_empty():
			p.wall_type = -1


## Nearest free worker to a cell (build-reserve preferred over harvesters,
## §3.2), ties to lowest id. Free = not already building or claiming a wall.
func _nearest_available_builder(pid: int, cell: int) -> SimEntity:
	var cx := grid.cell_center(cell % grid.width)
	var cy := grid.cell_center(cell / grid.width)
	var best: SimEntity = null
	var best_key := [1, 0x7FFFFFFFFFFFFFF]  # [is_harvester, dist2]; reserve wins
	for id in _sorted_ids():
		var w: SimEntity = entities[id]
		if not w.is_unit() or w.hp <= 0 or w.player != pid or not _is_worker(w):
			continue
		if w.build_target != 0 or w.wall_target_cell != -1:
			continue
		var dx := cx - w.x
		var dy := cy - w.y
		var d2 := Fixed.mul(dx, dx) + Fixed.mul(dy, dy)
		var is_harv := 0 if w.harvest_role == 0 else 1
		if is_harv < best_key[0] or (is_harv == best_key[0] and d2 < best_key[1]):
			best = w
			best_key = [is_harv, d2]
	return best


func _within_cell_reach(w: SimEntity, cell: int) -> bool:
	var cx := grid.cell_center(cell % grid.width)
	var cy := grid.cell_center(cell / grid.width)
	var reach := w.radius + SimGrid.CELL + HARVEST_REACH
	var dx := cx - w.x
	var dy := cy - w.y
	if absi(dx) > reach or absi(dy) > reach:
		return false
	return Fixed.mul(dx, dx) + Fixed.mul(dy, dy) <= Fixed.mul(reach, reach)


func _move_to_cell(w: SimEntity, cell: int) -> void:
	var c := SimCommand.new(w.player, SimCommand.Kind.MOVE)
	c.targets = [w.id]
	c.params = {"x": grid.cell_center(cell % grid.width),
			"y": grid.cell_center(cell / grid.width), "internal": true}
	_order_move(c)


# --- structure lifecycle (design_m3.md §4.5) -----------------------------------


func _structures_system() -> void:
	for id in _sorted_ids():
		var e: SimEntity = entities[id]
		if e.kind != SimEntity.Kind.STRUCTURE or e.hp <= 0:
			continue
		match e.build_state:
			SimEntity.BuildState.CAPSULE:
				_capsule_tick(e)
			SimEntity.BuildState.GROWING:
				_grow_tick(e)
			SimEntity.BuildState.COMPLETE:
				_regen_tick(e)


func _capsule_tick(e: SimEntity) -> void:
	if e.build_ticks_left > 0:
		e.build_ticks_left -= Fixed.ONE
		if e.build_ticks_left > 0:
			return
	# Trying to land (and retrying every tick while hovering).
	if e.vent_id != 0:
		# The vent blocks its own cells, so the static-blocker rule is
		# replaced by "is the vent still free?" — another siphon may have
		# claimed it mid-flight.
		if _siphon_on_excluding(e.vent_id, e.id) != 0:
			e.hp = 0 # destroyed, nothing refunds
			return
	else:
		for fy in range(e.foot_y, e.foot_y + e.foot_h):
			for fx in range(e.foot_x, e.foot_x + e.foot_w):
				if grid.is_blocked(fx, fy):
					e.hp = 0 # landed on a static blocker: the stake is lost
					return
		if _units_on_footprint(e):
			return # hover: stay airborne, retry next tick
	# Land and start growing.
	grid.block_rect(e.foot_x, e.foot_y, e.foot_w, e.foot_h)
	e.blocks = true
	e.build_state = SimEntity.BuildState.GROWING
	e.hp = maxi(1, e.max_hp / 10)
	e.build_ticks_left = Fixed.from_int(catalog.sim_of(e.type_key)["build_time"])


func _siphon_on_excluding(vent_id: int, self_id: int) -> int:
	for id in _sorted_ids():
		var e: SimEntity = entities[id]
		if e.id != self_id and e.kind == SimEntity.Kind.STRUCTURE \
				and e.hp > 0 and e.vent_id == vent_id:
			return id
	return 0


func _units_on_footprint(e: SimEntity) -> bool:
	var x0 := e.foot_x * SimGrid.CELL
	var y0 := e.foot_y * SimGrid.CELL
	var x1 := (e.foot_x + e.foot_w) * SimGrid.CELL
	var y1 := (e.foot_y + e.foot_h) * SimGrid.CELL
	for id in entities:
		var u: SimEntity = entities[id]
		if not u.is_unit() or u.hp <= 0:
			continue
		var px := clampi(u.x, x0, x1)
		var py := clampi(u.y, y0, y1)
		if absi(u.x - px) < u.radius and absi(u.y - py) < u.radius:
			return true
	return false


## Growth: 1 tick/tick plus assist bonus; hp ramps linearly from 10% so
## attacking a half-built nest meets half the hp. Damage taken during
## growth persists (the ramp adds deltas, it doesn't set totals).
func _grow_tick(e: SimEntity) -> void:
	var total := Fixed.from_int(catalog.sim_of(e.type_key)["build_time"])
	# Worker-built structures (needs_builder) make no progress on their own:
	# all progress is the build_rate a worker on site contributes via
	# assist_bonus (design_m4.md §4.1). Pull the worker and it freezes.
	var auto := 0 if e.needs_builder else Fixed.ONE
	var progress := auto + e.assist_bonus
	e.assist_bonus = 0
	var prev := e.build_ticks_left
	e.build_ticks_left = maxi(0, prev - progress)
	e.hp = mini(e.max_hp,
			e.hp + _ramp_hp(e.max_hp, total, e.build_ticks_left) - _ramp_hp(e.max_hp, total, prev))
	if e.build_ticks_left == 0:
		e.build_state = SimEntity.BuildState.COMPLETE
		_on_structure_complete(e)


## Target hp at a given remaining-build time: 10% of max at the start,
## max when done (integer math, monotone in progress).
func _ramp_hp(max_hp: int, total: int, left: int) -> int:
	var base := maxi(1, max_hp / 10)
	if total <= 0:
		return max_hp
	return base + (max_hp - base) * (total - left) / total


## Fires exactly once per structure (§4.5). Auras, bandwidth, and sight
## need no wiring — they're evaluated from live state and start answering
## differently the moment build_state flips.
func _on_structure_complete(e: SimEntity) -> void:
	var s := catalog.sim_of(e.type_key)
	# A Refinery auto-links every Flux vent within refinery_radius at COMPLETE
	# (design_m4.md §3.1), ascending vent id; vents don't move, so resolve once.
	if s.get("is_refinery", false):
		var r: int = s["refinery_radius"]
		if r <= 0:
			r = catalog.globals["refinery_radius"]
		e.linked_vents = PackedInt32Array()
		for id in _sorted_ids():
			var n: SimEntity = entities[id]
			if n.is_resource() and n.resource_kind == CatalogSchema.ResourceKind.FLUX \
					and _circle_covers(e.x, e.y, r, n.x, n.y):
				e.linked_vents.append(id)
	var pool: int = s["nano_pool"]
	if pool > 0:
		match s["default_allocation"]:
			CatalogSchema.Allocation.ALLOY:
				e.nano_alloc = [pool, 0, 0]
			CatalogSchema.Allocation.FLUX:
				e.nano_alloc = [0, pool, 0]
			CatalogSchema.Allocation.ASSIST:
				e.nano_alloc = [0, 0, pool]
			_:
				e.nano_alloc = [0, 0, 0]


## Aura regen plus repair-nano healing, both accrued fractionally in
## heal_acc and applied in whole points.
func _regen_tick(e: SimEntity) -> void:
	if e.hp >= e.max_hp:
		e.heal_acc = 0
		return
	e.heal_acc += eff_hp_regen(e) / TICK_RATE
	if e.heal_acc >= Fixed.ONE:
		var whole := Fixed.to_int(e.heal_acc)
		e.hp = mini(e.max_hp, e.hp + whole)
		e.heal_acc -= Fixed.from_int(whole)


# --- auras and territory (design_m3.md §4.3) ---------------------------------


## A functional entity acts, projects auras and sight, and counts for
## bandwidth: live units and COMPLETE structures. Growing structures,
## capsules, and resources never qualify (§4.5: a nest dropped deep in
## fog grows blind).
func _functional(e: SimEntity) -> bool:
	if e == null or e.hp <= 0 or e.is_resource():
		return false
	if e.kind == SimEntity.Kind.STRUCTURE \
			and e.build_state != SimEntity.BuildState.COMPLETE:
		return false
	return true


func _abilities_of(e: SimEntity) -> PackedInt32Array:
	if e.type_key == -1 or e.is_resource():
		return PackedInt32Array()
	return catalog.sim_of(e.type_key).get("abilities", PackedInt32Array())


func _rebuild_aura_index() -> void:
	_aura_sources.clear()
	for id in _sorted_ids():
		var e: SimEntity = entities[id]
		if not _functional(e):
			continue
		for ak in _abilities_of(e):
			var ab := catalog.sim_of(ak)
			if ab["ability_kind"] != CatalogSchema.AbilityKind.AURA:
				continue
			if not _aura_sources.has(e.player):
				_aura_sources[e.player] = {}
			var by_ability: Dictionary = _aura_sources[e.player]
			if not by_ability.has(ak):
				by_ability[ak] = []
			by_ability[ak].append([e.id, e.x, e.y, ab["radius"]])


## Is the point inside any active circle of this specific aura?
func in_aura(player: int, ability_key: int, x: int, y: int) -> bool:
	var by_ability: Dictionary = _aura_sources.get(player, {})
	for src: Array in by_ability.get(ability_key, []):
		if _circle_covers(src[1], src[2], src[3], x, y):
			return true
	return false


## Flag form for engine consumers ("in player P's territory"): each flag
## resolved to its granting ability ids at catalog compile time.
func in_flagged_aura(player: int, flag: String, x: int, y: int) -> bool:
	for ak in catalog.abilities_with_flag(flag):
		if in_aura(player, ak, x, y):
			return true
	return false


func _circle_covers(cx: int, cy: int, r: int, x: int, y: int) -> bool:
	var dx := x - cx
	var dy := y - cy
	if absi(dx) > r or absi(dy) > r:
		return false
	return Fixed.mul(dx, dx) + Fixed.mul(dy, dy) <= Fixed.mul(r, r)


## Effective incoming-damage multiplier for `e` (fixed): catalog base,
## improved by the best covering aura (lower is better). Stateless — a
## structure goes feral when its stronghold dies and recovers when a relay
## completes with no state transitions anywhere (§4.3).
func eff_damage_taken(e: SimEntity) -> int:
	var best := e.damage_taken
	for v in _modifier_values(e, "damage_taken"):
		best = mini(best, v)
	return best


## Effective hp regen for `e` (fixed hp/sec; base is 0 — regen only exists
## under an aura in M3).
func eff_hp_regen(e: SimEntity) -> int:
	var best := 0
	for v in _modifier_values(e, "hp_regen"):
		best = maxi(best, v)
	return best


## Values of modifier `key` from every aura covering `e` whose `affects`
## matches it. The same ability id never stacks with itself (circles of
## one ability contribute one value), and best-wins is order-independent.
func _modifier_values(e: SimEntity, key: String) -> Array[int]:
	var values: Array[int] = []
	var by_ability: Dictionary = _aura_sources.get(e.player, {})
	for ak: int in by_ability:
		var ab := catalog.sim_of(ak)
		var mods: Dictionary = ab["modifiers"]
		if not mods.has(key):
			continue
		if ab["affects"] == CatalogSchema.Affects.OWN_STRUCTURES \
				and e.kind != SimEntity.Kind.STRUCTURE:
			continue
		for src: Array in by_ability[ak]:
			if _circle_covers(src[1], src[2], src[3], e.x, e.y):
				values.append(mods[key])
				break
	return values


# --- vision and fog of war (design_m3.md §4.4) --------------------------------


## A build tile is visible to a player if its center is within `sight` of
## any of the player's functional entities. Two-state fog: terrain and
## resource nodes are always known; fog hides other players' dynamic
## entities. Derived data — recomputed from hashed state on a fixed
## cadence, never hashed itself.
func _recompute_vision() -> void:
	_rebuild_occluders()
	var pids := players.keys()
	pids.sort()
	for pid: int in pids:
		var vis := PackedByteArray()
		vis.resize(grid.tiles_w * grid.tiles_h)
		for id in _sorted_ids():
			var e: SimEntity = entities[id]
			if e.player != pid or not _functional(e) or e.sight <= 0:
				continue
			if e.is_underground():
				continue # burrowed units see nothing from down there
			_stamp_sight(vis, e)
		# Capsule detection (design_m4.md §6.3): a detector reveals enemy
		# aerial entities within its sight, even through fog and walls.
		for id in _sorted_ids():
			var det: SimEntity = entities[id]
			if det.player != pid or not _functional(det) or det.sight <= 0 \
					or not catalog.sim_of(det.type_key).get("detects_capsules", false):
				continue
			for eid in _sorted_ids():
				var cap: SimEntity = entities[eid]
				if cap.player == pid or not cap.is_aerial():
					continue
				if _within_dist(det.x, det.y, cap.x, cap.y, det.sight):
					_stamp_entity_tiles(vis, cap)
		_vision[pid] = vis


## Per-build-tile LOS height from standing structures (design_m4.md §6.5),
## rebuilt each vision tick (derived, never hashed). Vision is tile-resolution,
## so a sub-tile Barricade marks its whole tile an occluder — coarse but
## consistent, and a wall chain shadows a clean line. Written general so M5
## cliffs/ramps drop into the same height test.
func _rebuild_occluders() -> void:
	if _occluders.size() != grid.tiles_w * grid.tiles_h:
		_occluders.resize(grid.tiles_w * grid.tiles_h)
	for i in _occluders.size():
		_occluders[i] = 0
	_has_occluders = false
	for id in entities:
		var e: SimEntity = entities[id]
		if e.kind != SimEntity.Kind.STRUCTURE or e.hp <= 0 or not e.blocks:
			continue
		var h: int = catalog.sim_of(e.type_key).get("los_height", 0)
		if h <= 0:
			continue
		_has_occluders = true
		for fy in range(e.foot_y, e.foot_y + e.foot_h):
			for fx in range(e.foot_x, e.foot_x + e.foot_w):
				var tx := fx / SimGrid.PATH_SUBDIV
				var ty := fy / SimGrid.PATH_SUBDIV
				if tx >= 0 and ty >= 0 and tx < grid.tiles_w and ty < grid.tiles_h:
					_occluders[ty * grid.tiles_w + tx] = h


func _stamp_sight(vis: PackedByteArray, e: SimEntity) -> void:
	var r := e.sight
	var tx0 := maxi(0, Fixed.to_int(e.x - r))
	var tx1 := mini(grid.tiles_w - 1, Fixed.to_int(e.x + r))
	var ty0 := maxi(0, Fixed.to_int(e.y - r))
	var ty1 := mini(grid.tiles_h - 1, Fixed.to_int(e.y + r))
	var r2 := Fixed.mul(r, r)
	var sx := clampi(Fixed.to_int(e.x), 0, grid.tiles_w - 1)
	var sy := clampi(Fixed.to_int(e.y), 0, grid.tiles_h - 1)
	for ty in range(ty0, ty1 + 1):
		var dy := ty * Fixed.ONE + Fixed.HALF - e.y
		var dy2 := Fixed.mul(dy, dy)
		var row := ty * grid.tiles_w
		for tx in range(tx0, tx1 + 1):
			var dx := tx * Fixed.ONE + Fixed.HALF - e.x
			if Fixed.mul(dx, dx) + dy2 > r2:
				continue
			# Height-gated LOS (§6.5): a wall between source and tile occludes
			# it. The cheap open-ground disc skips this whole test.
			if _has_occluders and not _los_unoccluded(sx, sy, tx, ty):
				continue
			vis[row + tx] = 1


## True if the supercover line between two build tiles crosses no occluder
## tile before reaching the target (the source sees up to and including its
## own wall, §6.5).
func _los_unoccluded(x0: int, y0: int, x1: int, y1: int) -> bool:
	var w := grid.tiles_w
	var dx := absi(x1 - x0)
	var dy := absi(y1 - y0)
	var x := x0
	var y := y0
	var x_inc := 1 if x1 > x0 else -1
	var y_inc := 1 if y1 > y0 else -1
	var error := dx - dy
	dx *= 2
	dy *= 2
	while true:
		if x == x1 and y == y1:
			return true
		if (x != x0 or y != y0) and _occluders[y * w + x] > 0:
			return false  # a wall stands strictly between source and tile
		if error > 0:
			x += x_inc
			error -= dy
		elif error < 0:
			y += y_inc
			error += dx
		else:
			x += x_inc
			y += y_inc
			error -= dy
			error += dx
	return true


## Mark the build tiles an entity's footprint/position covers as visible.
func _stamp_entity_tiles(vis: PackedByteArray, e: SimEntity) -> void:
	var tx0 := clampi(Fixed.to_int(e.x - e.radius), 0, grid.tiles_w - 1)
	var tx1 := clampi(Fixed.to_int(e.x + e.radius), 0, grid.tiles_w - 1)
	var ty0 := clampi(Fixed.to_int(e.y - e.radius), 0, grid.tiles_h - 1)
	var ty1 := clampi(Fixed.to_int(e.y + e.radius), 0, grid.tiles_h - 1)
	for ty in range(ty0, ty1 + 1):
		for tx in range(tx0, tx1 + 1):
			vis[ty * grid.tiles_w + tx] = 1


func is_tile_visible(player: int, tx: int, ty: int) -> bool:
	if tx < 0 or ty < 0 or tx >= grid.tiles_w or ty >= grid.tiles_h:
		return false
	var vis: PackedByteArray = _vision.get(player, PackedByteArray())
	if vis.is_empty():
		return false
	return vis[ty * grid.tiles_w + tx] == 1


func is_cell_visible(player: int, cx: int, cy: int) -> bool:
	return is_tile_visible(player,
			cx / SimGrid.PATH_SUBDIV, cy / SimGrid.PATH_SUBDIV)


## Batch read for the view/minimap: one byte per build tile, row-major.
func vision_of(player: int) -> PackedByteArray:
	return _vision.get(player, PackedByteArray())


## Whether `player` can legitimately see entity `e` right now (design_m4.md
## §6.4–6.5) — the knowledge primitive the order resolver and view consult.
## Own entities always; aerial entities by radius only (seen over walls);
## ground entities only in a non-occluded visible tile.
func is_entity_visible(player: int, e: SimEntity) -> bool:
	if e == null or e.hp <= 0:
		return false
	if e.player == player:
		return true
	if e.is_aerial():
		for id in entities:
			var s: SimEntity = entities[id]
			if s.player == player and _functional(s) and s.sight > 0 \
					and _within_dist(s.x, s.y, e.x, e.y, s.sight):
				return true
		return false
	return is_tile_visible(player, Fixed.to_int(e.x), Fixed.to_int(e.y))


# --- win/loss (design_m4.md §7) -----------------------------------------------


## The town-hall rule: a player is eliminated the tick they first hold no
## COMPLETE `is_main` structure (§7.1). Latched in eliminated_tick and never
## cleared — a replacement that finishes after the latch does not save you.
func _check_elimination() -> void:
	var has_main := {}
	for id in entities:
		var e: SimEntity = entities[id]
		if e.kind == SimEntity.Kind.STRUCTURE and _functional(e) \
				and catalog.sim_of(e.type_key).get("is_main", false):
			has_main[e.player] = true
	for pid in players:
		var p: SimPlayer = players[pid]
		if has_main.get(pid, false):
			p.had_main = true
		elif p.had_main and p.eliminated_tick == -1:
			p.eliminated_tick = tick


## {"over": bool, "winner": int, "eliminated": {pid: tick}}. Match-over is
## derived: with two or more real players (id != 0), the match ends when at
## most one remains un-eliminated; winner 0 means none yet / a draw (§7.2).
func match_result() -> Dictionary:
	var alive: Array[int] = []
	var elim := {}
	var real := 0
	for pid in players:
		if pid == 0:
			continue
		real += 1
		elim[pid] = players[pid].eliminated_tick
		if players[pid].eliminated_tick == -1:
			alive.append(pid)
	var over := real >= 2 and alive.size() <= 1
	var winner := alive[0] if (over and alive.size() == 1) else 0
	return {"over": over, "winner": winner, "eliminated": elim}


# --- bandwidth (design_m3.md §4.1) --------------------------------------------


## {"used": int, "provided": int}. Derived on query, never stored, so it
## can never drift from the truth it summarizes. Used counts live units
## (plus queued trainees once production lands); provided counts COMPLETE
## structures.
func bandwidth_of(player: int) -> Dictionary:
	var used := 0
	var provided := 0
	for id in entities:
		var e: SimEntity = entities[id]
		if e.player != player or not _functional(e):
			continue
		if e.is_unit():
			used += catalog.sim_of(e.type_key)["bandwidth"]
		elif e.kind == SimEntity.Kind.STRUCTURE:
			provided += catalog.sim_of(e.type_key)["bandwidth_provided"]
			# Queued trainees reserve their bandwidth at queue time (§4.1).
			for q: Dictionary in e.train_queue:
				used += catalog.sim_of(q["type"])["bandwidth"]
	return {"used": used, "provided": provided}


# --- view read API (design_m3.md §4.11) ----------------------------------------
# Batch reads only — the view crosses the sim boundary O(1) times per tick,
# never in a per-entity query loop (GDExtension port discipline, §4.12).


## Floored balances for the HUD; the sim keeps fixed-point internally.
func resources_of(player: int) -> Dictionary:
	var p: SimPlayer = players.get(player)
	if p == null:
		return {"alloy": 0, "flux": 0}
	return {"alloy": Fixed.to_int(p.alloy), "flux": Fixed.to_int(p.flux)}


## Structure types a player can currently order: the union of
## `structures` across functional build abilities (design_m3.md §6.3).
func buildable_structures(player: int) -> PackedInt32Array:
	var seen := {}
	var result := PackedInt32Array()
	for id in _sorted_ids():
		var e: SimEntity = entities[id]
		if e.player != player or not _functional(e):
			continue
		for ak in _abilities_of(e):
			var ab := catalog.sim_of(ak)
			if ab["ability_kind"] != CatalogSchema.AbilityKind.BUILD:
				continue
			for type: int in ab["structures"]:
				if not seen.has(type):
					seen[type] = true
					result.append(type)
	return result


## The builder a BUILD command should name for this type: the first
## functional structure whose build ability sells it (lowest id), 0 if
## none. The UI resolves *who* before the command exists (§4.9).
func builder_for(player: int, type_key: int) -> int:
	for id in _sorted_ids():
		var e: SimEntity = entities[id]
		if e.player == player and _functional(e) \
				and _build_ability_for(e, type_key):
			return id
	return 0


## Unit types trainable right now (union of `trains` across the player's
## functional structures).
func trainable_units(player: int) -> PackedInt32Array:
	var seen := {}
	var result := PackedInt32Array()
	for id in _sorted_ids():
		var e: SimEntity = entities[id]
		if e.player != player or not _functional(e) \
				or e.kind != SimEntity.Kind.STRUCTURE:
			continue
		for type: int in catalog.sim_of(e.type_key)["trains"]:
			if not seen.has(type):
				seen[type] = true
				result.append(type)
	return result


## TRAIN target: the eligible structure with the shortest queue, lowest
## id tie-break (§6.5), 0 if none.
func train_structure_for(player: int, type_key: int) -> int:
	var best := 0
	var best_queue := TRAIN_QUEUE_MAX
	for id in _sorted_ids():
		var e: SimEntity = entities[id]
		if e.player != player or not _functional(e) \
				or e.kind != SimEntity.Kind.STRUCTURE:
			continue
		if type_key not in catalog.sim_of(e.type_key)["trains"]:
			continue
		if e.train_queue.size() < best_queue:
			best_queue = e.train_queue.size()
			best = id
	return best


## The player's nano-pool structures (Economy tab rows), ascending id.
func stronghold_ids(player: int) -> PackedInt32Array:
	var result := PackedInt32Array()
	for id in _sorted_ids():
		var e: SimEntity = entities[id]
		if e.player == player and _functional(e) \
				and e.kind == SimEntity.Kind.STRUCTURE \
				and catalog.sim_of(e.type_key)["nano_pool"] > 0:
			result.append(id)
	return result


## Structures of a player that can train units, with their queues
## ([{id, label_key, queue: [type_keys]}]) — the queue strip reads this.
func training_queues(player: int) -> Array:
	var result := []
	for id in _sorted_ids():
		var e: SimEntity = entities[id]
		if e.player != player or e.hp <= 0 \
				or e.kind != SimEntity.Kind.STRUCTURE:
			continue
		if catalog.sim_of(e.type_key)["trains"].is_empty():
			continue
		var queue := PackedInt32Array()
		for q: Dictionary in e.train_queue:
			queue.append(q["type"])
		result.append({"id": id, "type_key": e.type_key, "queue": queue,
				"head_left": 0 if e.train_queue.is_empty() else e.train_queue[0]["left"]})
	return result


## Flux vents as [{id, cx, cy, w, h, taken}] — the Build flow's siphon
## pick step reads this (§6.3: siphons skip placement search).
func vents() -> Array:
	var result := []
	for id in _sorted_ids():
		var e: SimEntity = entities[id]
		if e.is_resource() and e.resource_kind == CatalogSchema.ResourceKind.FLUX:
			result.append({"id": id, "cx": e.foot_x, "cy": e.foot_y,
					"w": e.foot_w, "h": e.foot_h, "taken": _siphon_on(id) != 0})
	return result


## Placement prediction helpers for the build UI (client-side mirror of
## the BUILD checks; the sim still revalidates on execution).
func vent_at(cx: int, cy: int, w: int, h: int) -> int:
	return _vent_at(cx, cy, w, h)


func vent_taken(vent_id: int) -> bool:
	return _siphon_on(vent_id) != 0


func territory_covers(player: int, x: int, y: int) -> bool:
	return in_flagged_aura(player, "territory", x, y)


## Active aura circles granting `flag` for a player, as [x, y, radius]
## fixed triples — the territory decal and minimap tint read these.
func flagged_aura_circles(player: int, flag: String) -> Array:
	var circles := []
	var by_ability: Dictionary = _aura_sources.get(player, {})
	for ak in catalog.abilities_with_flag(flag):
		for src: Array in by_ability.get(ak, []):
			circles.append([src[1], src[2], src[3]])
	return circles


# --- hashing ----------------------------------------------------------------


## Rolling hash over all authoritative sim state for desync detection.
## Derived data (flow cache, buckets) is excluded by design.
func state_hash() -> int:
	var h := 17
	h = (h * 31 + _data_hash) & 0x7FFFFFFFFFFFFFF
	h = (h * 31 + tick) & 0x7FFFFFFFFFFFFFF
	h = (h * 31 + rng.state) & 0x7FFFFFFFFFFFFFF
	h = (h * 31 + _next_entity_id) & 0x7FFFFFFFFFFFFFF
	h = grid.hash_into(h)
	var pids := players.keys()
	pids.sort()
	for pid in pids:
		h = players[pid].hash_into(h)
	for id in _sorted_ids():
		h = entities[id].hash_into(h)
	return h
