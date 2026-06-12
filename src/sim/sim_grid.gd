class_name SimGrid
extends RefCounted
## The sim's spatial grid. Two resolutions share one cell store:
##
##  - The *build grid* (1 tile = Fixed.ONE world units) that normal
##    structures snap to.
##  - The *pathing grid* (PATH_SUBDIV cells per tile side) that movement,
##    flow fields, and collision run on. Drawn barricade walls snap to
##    pathing cells, which is why footprints are stored in cells, not tiles
##    (see design.md "Structure footprints and drawn walls").
##
## Blocked state is a per-cell count so overlapping blockers (terrain +
## structure) compose; structures unblock their footprint on death.

const PATH_SUBDIV := 2
## Fixed-point world size of one pathing cell.
const CELL := Fixed.ONE / PATH_SUBDIV

var tiles_w: int
var tiles_h: int
## Dimensions in pathing cells.
var width: int
var height: int
## Bumped on every blocking change; flow fields cache against it.
var version: int = 0

var _blocked: PackedByteArray
## Content hash of _blocked, cached against `version` (derived data, so it
## is itself never hashed — only its value contributes via hash_into).
var _blocked_hash: int = 0
var _blocked_hash_version: int = -1


func _init(p_tiles_w: int, p_tiles_h: int) -> void:
	tiles_w = p_tiles_w
	tiles_h = p_tiles_h
	width = p_tiles_w * PATH_SUBDIV
	height = p_tiles_h * PATH_SUBDIV
	_blocked = PackedByteArray()
	_blocked.resize(width * height)


## Fixed-point world width/height of the map.
func world_w() -> int:
	return tiles_w * Fixed.ONE


func world_h() -> int:
	return tiles_h * Fixed.ONE


func index(cx: int, cy: int) -> int:
	return cy * width + cx


func in_bounds(cx: int, cy: int) -> bool:
	return cx >= 0 and cy >= 0 and cx < width and cy < height


## Out-of-bounds counts as blocked.
func is_blocked(cx: int, cy: int) -> bool:
	if not in_bounds(cx, cy):
		return true
	return _blocked[cy * width + cx] > 0


func is_blocked_index(i: int) -> bool:
	return _blocked[i] > 0


## Pathing cell coordinate containing fixed-point world coordinate `f`.
func cell_of(f: int) -> int:
	return (f * PATH_SUBDIV) >> Fixed.SHIFT


## Fixed-point world coordinate of a pathing cell's center.
func cell_center(c: int) -> int:
	return c * CELL + CELL / 2


func block_rect(cx: int, cy: int, w: int, h: int) -> void:
	_adjust_rect(cx, cy, w, h, 1)


func unblock_rect(cx: int, cy: int, w: int, h: int) -> void:
	_adjust_rect(cx, cy, w, h, -1)


func _adjust_rect(cx: int, cy: int, w: int, h: int, delta: int) -> void:
	for y in range(cy, cy + h):
		for x in range(cx, cx + w):
			assert(in_bounds(x, y), "blocking outside the grid")
			var i := y * width + x
			var v := _blocked[i] + delta
			assert(v >= 0 and v <= 255, "blocked count out of range")
			_blocked[i] = v
	version += 1


## True if every cell of the rect is in bounds and currently unblocked.
func rect_free(cx: int, cy: int, w: int, h: int) -> bool:
	for y in range(cy, cy + h):
		for x in range(cx, cx + w):
			if is_blocked(x, y):
				return false
	return true


## Nearest unblocked cell to (cx, cy), searching outward ring by ring in a
## fixed scan order so every peer picks the same cell. Returns -1 if none
## found within `max_radius` rings.
func nearest_free_cell(cx: int, cy: int, max_radius: int = 16) -> int:
	if not is_blocked(cx, cy):
		return index(cx, cy)
	for r in range(1, max_radius + 1):
		for dy in range(-r, r + 1):
			for dx in range(-r, r + 1):
				if maxi(absi(dx), absi(dy)) != r:
					continue
				var x := cx + dx
				var y := cy + dy
				if in_bounds(x, y) and not is_blocked(x, y):
					return index(x, y)
	return -1


## Read-only view of the blocked counts for hot pathing loops (avoids a
## method call per neighbor). Treat as const — writing to the returned
## array would silently copy-on-write and diverge from the grid.
func blocked_bytes() -> PackedByteArray:
	return _blocked


func hash_into(h: int) -> int:
	if _blocked_hash_version != version:
		_blocked_hash = SimHash.fnv_bytes(_blocked)
		_blocked_hash_version = version
	h = (h * 31 + version) & 0x7FFFFFFFFFFFFFF
	h = (h * 31 + _blocked_hash) & 0x7FFFFFFFFFFFFFF
	return h
