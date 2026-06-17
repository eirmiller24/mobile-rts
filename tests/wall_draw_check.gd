extends SceneTree
## Headless checks for the drawn-wall gesture's pure rasterizer (WallStroke,
## design_m4.md §4.4): a finger drag becomes an ordered, gap-free, de-duplicated
## run of in-bounds pathing cells suitable for a BUILD_WALL command. The sim
## side of BUILD_WALL (pending queue, blocking, cancel) lives in
## worker_build_check; this guards the view->command translation.
##
## Run on the host:
##   flatpak run org.godotengine.Godot --headless --path . \
##     -s res://tests/wall_draw_check.gd

const OFF := 8.0  # world_offset for a 16-tile grid (tiles_w / 2)

var failures := 0


func _initialize() -> void:
	_test_horizontal_run()
	_test_fast_drag_is_gapfree()
	_test_dedup_and_bounds()
	_test_start_cell_prepended()
	_test_snap()

	if failures == 0:
		print("wall_draw_check: OK")
		quit(0)
	else:
		print("wall_draw_check: FAILED (%d)" % failures)
		quit(1)


func _expect(cond: bool, msg: String) -> void:
	if not cond:
		push_error(msg)
		failures += 1


func _grid() -> SimGrid:
	return SimGrid.new(16, 16)  # width/height = 32 pathing cells


func _p(x: float, z: float) -> Vector3:
	return Vector3(x, 0.0, z)


func _cx(grid: SimGrid, cell: int) -> int:
	return cell % grid.width


func _cy(grid: SimGrid, cell: int) -> int:
	return cell / grid.width


## A straight horizontal drag lays a single contiguous row of cells, one per
## half-tile, in travel order with no repeats.
func _test_horizontal_run() -> void:
	var grid := _grid()
	var pts: Array = [_p(0.0, 0.0), _p(0.5, 0.0), _p(1.0, 0.0), _p(1.5, 0.0), _p(2.0, 0.0)]
	var cells := WallStroke.rasterize(grid, pts, OFF)
	_expect(cells.size() == 5, "horizontal drag -> 5 cells, got %d" % cells.size())
	var row := _cy(grid, cells[0])
	for i in cells.size():
		_expect(_cy(grid, cells[i]) == row, "all cells share a row")
		_expect(_cx(grid, cells[i]) == _cx(grid, cells[0]) + i, "columns advance by one")


## A drag that jumps across several cells in one sample still produces a
## 4-connected, gap-free wall (supercover fill) — movement can't slip through.
func _test_fast_drag_is_gapfree() -> void:
	var grid := _grid()
	var cells := WallStroke.rasterize(grid, [_p(0.0, 0.0), _p(3.0, 2.0)], OFF)
	_expect(cells.size() >= 6, "diagonal jump filled a run, got %d" % cells.size())
	for i in range(1, cells.size()):
		var d := absi(_cx(grid, cells[i]) - _cx(grid, cells[i - 1])) \
				+ absi(_cy(grid, cells[i]) - _cy(grid, cells[i - 1]))
		_expect(d == 1, "consecutive cells are 4-adjacent (gap-free), got step %d" % d)


## Back-and-forth over the same ground yields no duplicate cells.
func _test_dedup_and_bounds() -> void:
	var grid := _grid()
	var pts: Array = [_p(0.0, 0.0), _p(1.0, 0.0), _p(0.0, 0.0), _p(1.0, 0.0)]
	var cells := WallStroke.rasterize(grid, pts, OFF)
	var seen := {}
	for c: int in cells:
		_expect(not seen.has(c), "no duplicate cell %d" % c)
		seen[c] = true
		_expect(c >= 0 and c < grid.width * grid.height, "cell in bounds")
	# Points far off the map clamp into range rather than producing junk ids.
	var clamped := WallStroke.rasterize(grid, [_p(-999.0, -999.0), _p(999.0, 999.0)], OFF)
	for c: int in clamped:
		_expect(c >= 0 and c < grid.width * grid.height, "off-map point clamped in bounds")


## A snapped start cell leads the run and isn't duplicated by the path.
func _test_start_cell_prepended() -> void:
	var grid := _grid()
	var start := 10 * grid.width + 10
	var cells := WallStroke.rasterize(grid, [_p(0.0, 0.0), _p(1.0, 0.0)], OFF, start)
	_expect(cells.size() >= 1 and cells[0] == start, "start cell leads the run")
	var count := 0
	for c: int in cells:
		if c == start:
			count += 1
	_expect(count == 1, "start cell appears exactly once")


## snap_cell returns the nearest candidate within range, -1 beyond it.
func _test_snap() -> void:
	var grid := _grid()
	var post := 16 * grid.width + 16  # cell whose center is world (0.25, 0.25)
	var cands := PackedInt32Array([post])
	var near := WallStroke.snap_cell(grid, cands, 0.25, 0.25, OFF, 1.6)
	_expect(near == post, "snaps to a post within range")
	var far := WallStroke.snap_cell(grid, cands, 6.0, 6.0, OFF, 1.6)
	_expect(far == -1, "no snap beyond range")
	_expect(WallStroke.snap_cell(grid, PackedInt32Array(), 0.0, 0.0, OFF, 1.6) == -1,
			"empty candidate set never snaps")
