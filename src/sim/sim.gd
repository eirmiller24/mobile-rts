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
## Orders for this many units or fewer get per-unit A* paths; larger
## groups share one flow field per destination.
const SMALL_GROUP := 3
## A move order completes within this distance of the goal (fixed).
const ARRIVE_DIST := SimGrid.CELL
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


func _init(seed_value: int, p_catalog: CompiledCatalog, map: MapData) -> void:
	assert(p_catalog != null and p_catalog.ok(), "sim needs a valid catalog")
	rng = DRng.new(seed_value)
	catalog = p_catalog
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
				spawn_structure(obj["player"], obj["cx"], obj["cy"], obj["type_key"])
			"resource":
				spawn_resource(obj["cx"], obj["cy"], obj["type_key"])


## Schedule a command for execution. Lockstep peers must schedule identical
## commands for identical ticks.
func schedule(cmd: SimCommand, at_tick: int = -1) -> void:
	var t := at_tick if at_tick >= 0 else tick + COMMAND_DELAY
	assert(t >= tick, "cannot schedule a command in the past")
	if not _command_queue.has(t):
		_command_queue[t] = []
	_command_queue[t].append(cmd)


## Advance the sim by exactly one tick.
func step() -> void:
	_execute_scheduled_commands()
	_run_flow_builds()
	_movement_system()
	_combat_system()
	_reap()
	tick += 1


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
## big). Returns 0 if any footprint cell is blocked.
func spawn_structure(player: int, cx: int, cy: int, type_key: int) -> int:
	assert(catalog.kind_of(type_key) == "structure")
	var s := catalog.sim_of(type_key)
	var w: int = s["foot_w"]
	var h: int = s["foot_h"]
	if not grid.rect_free(cx, cy, w, h):
		return 0
	var e := _place_footprint(player, cx, cy, type_key, s)
	e.kind = SimEntity.Kind.STRUCTURE
	_copy_combat_stats(e, s)
	return e.id


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
			# Interim debug form: place a complete structure of a catalog
			# type. The vision-gated lifecycle build replaces this in M3
			# step 4 (design_m3.md §4.5).
			spawn_structure(cmd.player_id,
					cmd.params.get("cx", 0), cmd.params.get("cy", 0),
					cmd.params.get("type", -1))
		SimCommand.Kind.DEBUG_SPAWN:
			spawn_unit(cmd.player_id,
					cmd.params.get("x", 0), cmd.params.get("y", 0),
					cmd.params.get("type", -1))
		_:
			pass # Remaining kinds land in M3+.


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
				e.path = Pathing.astar(grid, from, goal)
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
		if not e.is_unit() or e.hp <= 0:
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
		if not e.is_unit() or e.hp <= 0:
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
	var nxt: int = entry["next"][cur]
	if nxt == -1:
		return GIVE_UP
	return Vector2i(grid.cell_center(nxt % grid.width), grid.cell_center(nxt / grid.width))


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
	# Record the destination's group key (not the personal slot cell) so
	# crowd arrival matches across slot-mates of the same order.
	e.done_goal_key = e.orders[0].get("group", e.goal_key)
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
		if e.cooldown > 0:
			e.cooldown -= 1
		var t: SimEntity = entities.get(e.target_id) if e.target_id != 0 else null
		if t != null and (t.hp <= 0 or not t.targetable or t.player == e.player
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
			t.hp -= dmg
			e.cooldown = e.cooldown_ticks


## Active ATTACK_MOVE target standing in attack range (movement pauses).
func _engaged(e: SimEntity) -> bool:
	if e.target_id == 0:
		return false
	var t: SimEntity = entities.get(e.target_id)
	return t != null and t.hp > 0 and t.player != e.player \
			and _in_range(e, t, e.attack_range, true)


## Nearest live enemy within acquire range; ties go to the lowest id.
func _acquire(e: SimEntity) -> SimEntity:
	var best: SimEntity = null
	var best_d2 := Fixed.mul(e.acquire_range, e.acquire_range)
	var reach := (e.acquire_range >> BUCKET_SHIFT) + 1
	for nid in _bucket_neighbors(e, reach, 0):
		var n: SimEntity = entities[nid]
		if n.hp <= 0 or not n.targetable or n.player == e.player:
			continue
		var dx := n.x - e.x
		var dy := n.y - e.y
		var d2 := Fixed.mul(dx, dx) + Fixed.mul(dy, dy)
		# Nearest, ties to the lowest id (neighbor iteration is not
		# id-sorted, so the tie-break must be explicit).
		if d2 < best_d2 or (d2 == best_d2 and (best == null or n.id < best.id)):
			best_d2 = d2
			best = n
	return best


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
		if not e.is_unit():
			grid.unblock_rect(e.foot_x, e.foot_y, e.foot_w, e.foot_h)
		entities.erase(id)


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
