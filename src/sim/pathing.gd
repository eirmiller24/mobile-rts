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


## A* from `from_index` to `to_index`. Returns the path as cell indices,
## excluding the start cell and including the goal; empty if unreachable
## or already there.
static func astar(grid: SimGrid, from_index: int, to_index: int) -> PackedInt32Array:
	var path := PackedInt32Array()
	if from_index == to_index:
		return path
	var n := grid.width * grid.height
	var g := PackedInt32Array()
	g.resize(n)
	g.fill(UNREACHABLE)
	var came := PackedInt32Array()
	came.resize(n)
	came.fill(-1)

	var tx := to_index % grid.width
	var ty := to_index / grid.width
	var heap := PackedInt64Array()
	g[from_index] = 0
	_heap_push_keyed(heap, _octile(from_index % grid.width, from_index / grid.width, tx, ty), from_index)

	while heap.size() > 0:
		var entry := _heap_pop(heap)
		var u := int(entry & INDEX_MASK)
		var ux := u % grid.width
		var uy := u / grid.width
		var f := int(entry >> INDEX_BITS)
		if f != g[u] + _octile(ux, uy, tx, ty):
			continue # stale entry
		if u == to_index:
			break
		for dir in DIRS:
			var vx := ux + dir.x
			var vy := uy + dir.y
			if grid.is_blocked(vx, vy):
				continue
			if not _diagonal_open(grid, ux, uy, dir):
				continue
			var cost := COST_DIAGONAL if dir.x != 0 and dir.y != 0 else COST_STRAIGHT
			var v := vy * grid.width + vx
			var ng := g[u] + cost
			if ng < g[v]:
				g[v] = ng
				came[v] = u
				_heap_push_keyed(heap, ng + _octile(vx, vy, tx, ty), v)

	if came[to_index] == -1:
		return path
	var c := to_index
	while c != from_index:
		path.append(c)
		c = came[c]
	path.reverse()
	return path


## Diagonal moves require both adjacent orthogonals open (no corner cutting).
static func _diagonal_open(grid: SimGrid, ux: int, uy: int, dir: Vector2i) -> bool:
	if dir.x == 0 or dir.y == 0:
		return true
	return not grid.is_blocked(ux + dir.x, uy) and not grid.is_blocked(ux, uy + dir.y)


## Octile distance in the same cost units as the step costs (admissible).
static func _octile(ax: int, ay: int, bx: int, by: int) -> int:
	var dx := absi(ax - bx)
	var dy := absi(ay - by)
	return COST_STRAIGHT * maxi(dx, dy) + (COST_DIAGONAL - COST_STRAIGHT) * mini(dx, dy)


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
