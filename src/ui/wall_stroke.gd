class_name WallStroke
## Pure rasterizer for the drawn-wall gesture (design_m4.md §4.4): turns a
## finger drag — a polyline of world points — into the ordered, de-duplicated
## set of pathing cells it crosses, ready for a BUILD_WALL command. Kept free
## of any node/input state so it is unit-testable headless; the gesture code
## feeds it points and renders the cells it returns.
##
## Cells are pathing cells (SimGrid.PATH_SUBDIV per tile), matching the 1x1
## Barricade footprint and the sim's wall plan. A cell id is cy*grid.width+cx.

## World point -> pathing cell (cx, cy), clamped into the grid.
static func cell_at(grid: SimGrid, world_x: float, world_y: float,
		world_offset: float) -> Vector2i:
	var cx := int(floor((world_x + world_offset) * SimGrid.PATH_SUBDIV))
	var cy := int(floor((world_y + world_offset) * SimGrid.PATH_SUBDIV))
	return Vector2i(clampi(cx, 0, grid.width - 1), clampi(cy, 0, grid.height - 1))


## Rasterize a polyline (world coords, the drag samples) into an ordered list
## of unique in-bounds cell ids. Consecutive samples are joined with a grid
## walk (supercover line) so a fast drag that skips pixels still lays a
## contiguous, gap-free wall. `start_cell` (>= 0), when given, is prepended so
## a Control-snapped stroke begins exactly on an existing post.
static func rasterize(grid: SimGrid, points: Array, world_offset: float,
		start_cell: int = -1) -> PackedInt32Array:
	var cells := PackedInt32Array()
	var seen := {}
	var push := func(cx: int, cy: int) -> void:
		if cx < 0 or cy < 0 or cx >= grid.width or cy >= grid.height:
			return
		var id := cy * grid.width + cx
		if not seen.has(id):
			seen[id] = true
			cells.append(id)
	if start_cell >= 0 and start_cell < grid.width * grid.height:
		push.call(start_cell % grid.width, start_cell / grid.width)
	var prev := Vector2i(-9999, -9999)
	for p: Vector2 in _as_points(points):
		var c := cell_at(grid, p.x, p.y, world_offset)
		if prev.x == -9999:
			push.call(c.x, c.y)
		else:
			for step: Vector2i in _line_cells(prev, c):
				push.call(step.x, step.y)
		prev = c
	return cells


## Accept either Array[Vector2] or Array[Vector3] (xz plane) drag samples.
static func _as_points(points: Array) -> Array:
	var out: Array = []
	for p: Variant in points:
		if p is Vector3:
			out.append(Vector2(p.x, p.z))
		else:
			out.append(p)
	return out


## Every cell on the grid line between two cells, inclusive of the far end
## (the near end is assumed already emitted). Supercover-ish: steps one axis
## at a time so diagonals fill both shoulder cells and leave no movement gap.
static func _line_cells(a: Vector2i, b: Vector2i) -> Array:
	var out: Array = []
	var x := a.x
	var y := a.y
	var dx := absi(b.x - a.x)
	var dy := absi(b.y - a.y)
	var sx := 1 if b.x > a.x else -1
	var sy := 1 if b.y > a.y else -1
	var err := dx - dy
	while x != b.x or y != b.y:
		var e2 := 2 * err
		if e2 > -dy:
			err -= dy
			x += sx
		elif e2 < dx:
			err += dx
			y += sy
		out.append(Vector2i(x, y))
	return out


## Nearest cell in `candidate_cells` to a world point, within `max_dist`
## world units, or -1. Used to snap a stroke's start onto an existing post
## (the precise-wall workflow: tap a post, hold Control, draw from it).
static func snap_cell(grid: SimGrid, candidate_cells: PackedInt32Array,
		world_x: float, world_y: float, world_offset: float,
		max_dist: float) -> int:
	var best := -1
	var best_d := max_dist
	for id: int in candidate_cells:
		var cx := id % grid.width
		var cy := id / grid.width
		var wx := (cx + 0.5) / SimGrid.PATH_SUBDIV - world_offset
		var wy := (cy + 0.5) / SimGrid.PATH_SUBDIV - world_offset
		var d := Vector2(wx - world_x, wy - world_y).length()
		if d < best_d:
			best_d = d
			best = id
	return best
