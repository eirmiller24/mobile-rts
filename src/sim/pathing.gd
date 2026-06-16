class_name Pathing
extends RefCounted
## Deterministic grid pathfinding (design.md "Pathfinding and movement"):
## flow fields for group orders, A* for small/single-unit orders. Both run
## on integer costs over the pathing grid and break ties by cell index, so
## every peer computes identical results.
##
## Pathing knows nothing about units — it supplies a desired direction per
## cell; unit collision is resolved separately in the movement system.

## Integer step costs (~1 : sqrt(2)).
const COST_STRAIGHT := 5
const COST_DIAGONAL := 7

const UNREACHABLE := 0x7FFFFFFF

## Fixed neighbor order: orthogonals first, then diagonals.
const DIRS: Array[Vector2i] = [
	Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1),
	Vector2i(1, 1), Vector2i(1, -1), Vector2i(-1, 1), Vector2i(-1, -1),
]

## Heap entries encode (priority << INDEX_BITS) | cell_index, so equal
## priorities tie-break on cell index and the heap never compares equal keys.
const INDEX_BITS := 24
const INDEX_MASK := (1 << INDEX_BITS) - 1


## Once every source cell is settled, keep expanding this much further
## (cost units; 40 = ~8 straight cells) so collision shoves rarely push a
## unit off the covered region, then stop.
const EARLY_STOP_MARGIN := 40

## Flat neighbor tables for the hot loop: orthogonals first, diagonals
## last (a diagonal k needs both adjacent orthogonals open).
const NDX: Array[int] = [1, -1, 0, 0, 1, 1, -1, -1]
const NDY: Array[int] = [0, 0, 1, -1, 1, -1, 1, -1]
const NCOST: Array[int] = [
	COST_STRAIGHT, COST_STRAIGHT, COST_STRAIGHT, COST_STRAIGHT,
	COST_DIAGONAL, COST_DIAGONAL, COST_DIAGONAL, COST_DIAGONAL,
]


## Resumable flow-field build: Dijkstra outward from `goal_index`,
## advanced in pop-budgeted slices by Sim (a fixed operation count per
## tick — deterministic, unlike wall time) so a full-map build never
## freezes a single tick. When finished (`done`):
##   next[c] = index of the next cell toward the goal (-1 = none),
##   dist[c] = settled cost (UNREACHABLE = never reached),
##   full    = whether the whole reachable map was explored.
##
## With `sources` given, the search stops EARLY_STOP_MARGIN past the last
## source instead of exploring the whole map (full = false) — callers must
## rebuild without sources when they query a cell outside the covered
## region. With no sources, UNREACHABLE is authoritative.
##
## Uses Dial's algorithm: edge costs are 5/7, so a ring of 8 distance
## buckets replaces a binary heap with O(1) push/pop. Pop order within a
## bucket is LIFO — arbitrary but identical on every peer, which is all
## determinism needs. This is the sim's hottest loop (a full 128x128 build
## relaxes ~130k edges), so everything is inlined — keep it ugly.
class FlowBuild:
	var goal_index: int
	## Grid version this build started against; the blocked snapshot below
	## is copy-on-write, so later grid edits don't corrupt the build — Sim
	## discards the result if the version moved.
	var grid_version: int
	var next: PackedInt32Array
	var dist: PackedInt32Array
	var full := true
	var done := false

	var _w: int
	var _h: int
	var _blocked: PackedByteArray
	var _settled: PackedByteArray
	var _buckets := [[], [], [], [], [], [], [], []]
	var _remaining := 0
	var _cur_d := 0
	var _pending := {}
	var _stop_dist := -1

	func _init(grid: SimGrid, p_goal: int, sources: PackedInt32Array) -> void:
		goal_index = p_goal
		grid_version = grid.version
		_w = grid.width
		_h = grid.height
		_blocked = grid.blocked_bytes()
		var n := _w * _h
		next.resize(n)
		next.fill(-1)
		dist.resize(n)
		dist.fill(Pathing.UNREACHABLE)
		_settled.resize(n)
		for s in sources:
			if s != p_goal and _blocked[s] == 0:
				_pending[s] = true
		dist[p_goal] = 0
		_buckets[0].push_back(p_goal)
		_remaining = 1

	## Advance by at most `max_pops` queue pops. Returns pops consumed;
	## check `done` for completion.
	func run(max_pops: int) -> int:
		if done:
			return 0
		var pops := 0
		while _remaining > 0 and pops < max_pops:
			var b: Array = _buckets[_cur_d & 7]
			if b.is_empty():
				_cur_d += 1 # window property: a filled bucket is <= 7 away
				continue
			var u: int = b.pop_back()
			_remaining -= 1
			pops += 1
			if _settled[u] == 1 or dist[u] != _cur_d:
				continue # stale entry (lazy deletion)
			if _stop_dist >= 0 and _cur_d > _stop_dist:
				full = false
				_remaining = 0
				break
			_settled[u] = 1
			if not _pending.is_empty() and _pending.erase(u) and _pending.is_empty():
				_stop_dist = _cur_d + Pathing.EARLY_STOP_MARGIN
			var ux := u % _w
			var uy := u / _w
			for k in 8:
				var vx := ux + Pathing.NDX[k]
				var vy := uy + Pathing.NDY[k]
				if vx < 0 or vy < 0 or vx >= _w or vy >= _h:
					continue
				var v := vy * _w + vx
				if _blocked[v] != 0:
					continue
				# Diagonals need both orthogonals open (no corner cut).
				if k >= 4 and (_blocked[uy * _w + vx] != 0 or _blocked[vy * _w + ux] != 0):
					continue
				var nd := _cur_d + Pathing.NCOST[k]
				if nd < dist[v]:
					dist[v] = nd
					next[v] = u
					_buckets[nd & 7].push_back(v)
					_remaining += 1
		if _remaining == 0:
			done = true
			_buckets = []
			_settled = PackedByteArray()
			_blocked = PackedByteArray()
			_pending = {}
		return pops


## Lazy Theta* from `from_index` to `to_index`: any-angle pathfinding over
## the same pathing grid. Returns the path as cell indices, excluding the
## start cell and including the goal; empty if unreachable or already there.
##
## Unlike plain A*, a node's parent may be any earlier node with line of
## sight (not just the cell it was expanded from), so the path is a chain
## of straight any-angle segments through corners — units no longer step in
## 45-degree increments. The "lazy" variant assumes line of sight when
## relaxing (cheap) and only verifies it when the node is popped, re-parenting
## to the best settled neighbor if the assumption was wrong.
##
## Costs are integer Euclidean distances scaled by COST_STRAIGHT (see
## _euclid), so they share units with the flow field's 5/7 step costs. The
## heuristic is the same straight-line distance — admissible for any-angle
## movement (octile would overestimate it).
static func theta_star(grid: SimGrid, from_index: int, to_index: int) -> PackedInt32Array:
	var path := PackedInt32Array()
	if from_index == to_index:
		return path
	var w := grid.width
	var n := w * grid.height
	var g := PackedInt32Array()
	g.resize(n)
	g.fill(UNREACHABLE)
	var parent := PackedInt32Array()
	parent.resize(n)
	parent.fill(-1)
	var closed := PackedByteArray()
	closed.resize(n)

	var tx := to_index % w
	var ty := to_index / w
	var heap := PackedInt64Array()
	g[from_index] = 0
	parent[from_index] = from_index # the root is its own parent
	_heap_push_keyed(heap, _euclid(from_index % w, from_index / w, tx, ty), from_index)

	while heap.size() > 0:
		var entry := _heap_pop(heap)
		var u := int(entry & INDEX_MASK)
		if closed[u] == 1:
			continue # stale heap entry (lazy deletion)
		var ux := u % w
		var uy := u / w
		# Lazy set-vertex: the parent recorded during relaxation assumed line
		# of sight. Verify it now; if it fails, re-parent u to the settled
		# neighbor that reaches it most cheaply (ties to the lowest index).
		var pu := parent[u]
		if pu != u and not los(grid, pu, u):
			var best_g := UNREACHABLE
			var best_p := -1
			for dir in DIRS:
				var vx := ux + dir.x
				var vy := uy + dir.y
				if not grid.in_bounds(vx, vy):
					continue
				if not _diagonal_open(grid, ux, uy, dir):
					continue # a diagonal re-parent must not cut a blocked corner
				var v := vy * w + vx
				if closed[v] != 1:
					continue
				var cg := g[v] + _euclid(vx, vy, ux, uy)
				if best_p == -1 or cg < best_g or (cg == best_g and v < best_p):
					best_g = cg
					best_p = v
			if best_p == -1:
				continue # no settled neighbor sees u; drop it
			parent[u] = best_p
			g[u] = best_g
			pu = best_p
		closed[u] = 1
		if u == to_index:
			break
		var pux := pu % w
		var puy := pu / w
		for dir in DIRS:
			var vx := ux + dir.x
			var vy := uy + dir.y
			if grid.is_blocked(vx, vy):
				continue
			if not _diagonal_open(grid, ux, uy, dir):
				continue
			var v := vy * w + vx
			if closed[v] == 1:
				continue
			# Path 2 (optimistic): route v straight from u's parent, assuming
			# line of sight — checked when v is later popped.
			var ng := g[pu] + _euclid(pux, puy, vx, vy)
			if ng < g[v]:
				g[v] = ng
				parent[v] = pu
				_heap_push_keyed(heap, ng + _euclid(vx, vy, tx, ty), v)

	if parent[to_index] == -1:
		return path
	var c := to_index
	while c != from_index:
		path.append(c)
		c = parent[c]
	path.reverse()
	return path


## True if a straight line between the two cells' centers crosses only
## unblocked cells. Integer supercover traversal (deterministic, no floats):
## walks every cell the segment touches, and at an exact corner crossing
## rejects the move unless both flanking cells are open (no corner cutting,
## matching _diagonal_open).
static func los(grid: SimGrid, c0: int, c1: int) -> bool:
	var w := grid.width
	var x0 := c0 % w
	var y0 := c0 / w
	var x1 := c1 % w
	var y1 := c1 / w
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
		if grid.is_blocked(x, y):
			return false
		if x == x1 and y == y1:
			return true # reached the endpoint with everything clear
		if error > 0:
			x += x_inc
			error -= dy
		elif error < 0:
			y += y_inc
			error += dx
		else:
			# Segment passes exactly through the corner shared by four cells;
			# reject if either cell flanking the diagonal step is blocked.
			if grid.is_blocked(x + x_inc, y) or grid.is_blocked(x, y + y_inc):
				return false
			x += x_inc
			y += y_inc
			error -= dy
			error += dx
	return true # unreachable


## Diagonal moves require both adjacent orthogonals open (no corner cutting).
static func _diagonal_open(grid: SimGrid, ux: int, uy: int, dir: Vector2i) -> bool:
	if dir.x == 0 or dir.y == 0:
		return true
	return not grid.is_blocked(ux + dir.x, uy) and not grid.is_blocked(ux, uy + dir.y)


## Straight-line distance between two cells in step-cost units: floor of
## COST_STRAIGHT * sqrt(dx^2 + dy^2), computed as isqrt(25*(dx^2+dy^2)) so it
## stays integer and deterministic. Admissible as a Theta* heuristic.
static func _euclid(ax: int, ay: int, bx: int, by: int) -> int:
	var dx := ax - bx
	var dy := ay - by
	return _isqrt(COST_STRAIGHT * COST_STRAIGHT * (dx * dx + dy * dy))


## Floor of the integer square root via Newton's method (deterministic,
## same shape as Fixed.sqrt but on a plain integer).
static func _isqrt(v: int) -> int:
	if v <= 0:
		return 0
	var bits := 0
	var t := v
	while t > 0:
		t >>= 1
		bits += 1
	var x := 1 << ((bits + 1) >> 1) # 2^ceil(bits/2) > sqrt(v): a valid seed
	while true:
		var nx := (x + v / x) >> 1
		if nx >= x:
			return x
		x = nx
	return x # unreachable


static func _heap_push_keyed(heap: PackedInt64Array, priority: int, cell_index: int) -> void:
	_heap_push(heap, (priority << INDEX_BITS) | cell_index)


static func _heap_push(heap: PackedInt64Array, value: int) -> void:
	heap.push_back(value)
	var i := heap.size() - 1
	while i > 0:
		var p := (i - 1) >> 1
		if heap[p] <= heap[i]:
			break
		var t := heap[p]
		heap[p] = heap[i]
		heap[i] = t
		i = p


static func _heap_pop(heap: PackedInt64Array) -> int:
	var top := heap[0]
	var last := heap[heap.size() - 1]
	heap.resize(heap.size() - 1)
	if heap.size() > 0:
		heap[0] = last
		var i := 0
		while true:
			var l := 2 * i + 1
			var r := l + 1
			var s := i
			if l < heap.size() and heap[l] < heap[s]:
				s = l
			if r < heap.size() and heap[r] < heap[s]:
				s = r
			if s == i:
				break
			var t := heap[s]
			heap[s] = heap[i]
			heap[i] = t
			i = s
	return top
