class_name ConsoleView
extends Control
## The command console (design.md "The Command Console"): a sheet that
## slides up from the bottom edge between three detents — peek (just the
## grab handle), half (viewport still orderable above), and full. Tabs,
## screens, and widgets are built entirely from the UI catalog's console
## section; this view is an interpreter, not a layout.
##
## M1 scope: structure and gestures only. Widget actions either navigate
## between screens or do nothing yet.

enum Detent { PEEK, HALF, FULL }

const HANDLE_H := 52.0
const TABS_H := 48.0
const HEADER_H := 40.0
## Release velocity (px/s, +down) thresholds: a hard fling carries the
## sheet all the way to the far detent regardless of where the thumb lifts;
## a softer flick steps one detent; below that we settle to the nearest.
const FLING_VELOCITY := 1100.0
const STEP_VELOCITY := 320.0
## Pathing-cell margin an auto-placed building tries to keep clear on every
## side, so it doesn't wall off a lane (the build-at-a-location convenience).
const CLEARANCE := 1

var catalog: UICatalog
## Game access for live widgets (set by the HUD before add_child); null
## keeps the console structural-only (ui_catalog_check, M1 demos).
var ctx: GameUIContext
var detent := Detent.PEEK

## Structure type armed by the Build flow, awaiting a placement choice
## (design_m3.md §6.3 screen 2); -1 when idle.
var _pending_build := -1
## Build-flow mode: a plain tap on the Build category does one structure
## then returns to the tab root; a long-press keeps the placement screen
## armed for repeated drops until Back. Set when the category is chosen.
var _continuous_build := false

var _handle: Handle
var _tab_bar: HBoxContainer
var _tab_buttons: Dictionary = {}
var _back_button: Button
var _title: Label
var _scroll: ScrollContainer
var _content: VBoxContainer

var _current_tab := ""
## tab id -> screen id currently shown there (console state is preserved
## per tab, per the design doc)
var _tab_screens: Dictionary = {}
var _dragging := false
var _grab_offset := 0.0
var _drag_start_top := 0.0
## Smoothed drag velocity (px/s, +down) and the last sample, for momentum.
var _drag_velocity := 0.0
var _last_drag_y := 0.0
var _last_drag_ms := 0


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP

	_handle = Handle.new()
	_handle.console = self
	add_child(_handle)

	_tab_bar = HBoxContainer.new()
	_tab_bar.add_theme_constant_override("separation", 8)
	add_child(_tab_bar)
	for tab in catalog.console_tabs:
		var btn := CategoryButton.new()
		btn.setup(tab.id, tab.label)
		btn.chosen.connect(_on_category_chosen)
		_tab_bar.add_child(btn)
		_tab_buttons[tab.id] = btn

	var header := HBoxContainer.new()
	header.name = "Header"
	add_child(header)
	_back_button = Button.new()
	_back_button.text = "<"
	_back_button.custom_minimum_size = Vector2(56, HEADER_H - 8.0)
	_back_button.pressed.connect(_on_back)
	header.add_child(_back_button)
	_title = Label.new()
	_title.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	header.add_child(_title)

	_scroll = ScrollContainer.new()
	add_child(_scroll)
	_content = VBoxContainer.new()
	_content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_content.add_theme_constant_override("separation", 10)
	_scroll.add_child(_content)

	get_viewport().size_changed.connect(_layout)
	_layout()
	position.y = _detent_top(Detent.PEEK)
	if not catalog.console_tabs.is_empty():
		_select_tab(catalog.console_tabs[0].id)


func _process(delta: float) -> void:
	if _dragging:
		return
	var target := _detent_top(detent)
	position.y = lerpf(position.y, target, minf(1.0, delta * 14.0))
	if absf(position.y - target) < 0.5:
		position.y = target


func is_open() -> bool:
	return detent != Detent.PEEK or _dragging


# Drag plumbing, driven by the Handle.

func begin_drag(pointer_y: float) -> void:
	_dragging = true
	_grab_offset = pointer_y - position.y
	_drag_start_top = position.y
	_drag_velocity = 0.0
	_last_drag_y = position.y
	_last_drag_ms = Time.get_ticks_msec()


func drag_to(pointer_y: float) -> void:
	position.y = clampf(pointer_y - _grab_offset,
			_detent_top(Detent.FULL), _detent_top(Detent.PEEK))
	var now := Time.get_ticks_msec()
	var dt := (now - _last_drag_ms) / 1000.0
	if dt > 0.0:
		# Bias toward the most recent sample so a fast lift-off reads as fast.
		_drag_velocity = lerpf(_drag_velocity, (position.y - _last_drag_y) / dt, 0.5)
	_last_drag_y = position.y
	_last_drag_ms = now


func end_drag(_held_for: float) -> void:
	_dragging = false
	# A pause before lift-off means no momentum, even if the last motion was
	# fast: decay the stored velocity toward zero past a short idle window.
	if Time.get_ticks_msec() - _last_drag_ms > 90:
		_drag_velocity = 0.0
	# Momentum decides the landing detent: a hard fling overshoots straight
	# to the far end even from mid-screen; a flick steps one; a slow release
	# just settles to whatever is nearest.
	if _drag_velocity <= -FLING_VELOCITY:
		detent = Detent.FULL
	elif _drag_velocity >= FLING_VELOCITY:
		detent = Detent.PEEK
	elif _drag_velocity <= -STEP_VELOCITY:
		detent = Detent.HALF if detent == Detent.PEEK else Detent.FULL
	elif _drag_velocity >= STEP_VELOCITY:
		detent = Detent.HALF if detent == Detent.FULL else Detent.PEEK
	else:
		detent = _nearest_detent()


func _detent_top(d: Detent) -> float:
	var vh := get_viewport().get_visible_rect().size.y
	match d:
		Detent.FULL:
			return vh * 0.08
		Detent.HALF:
			return vh * 0.55
		_:
			return vh - HANDLE_H
	return vh - HANDLE_H


func _nearest_detent() -> Detent:
	var best := Detent.PEEK
	var best_dist := INF
	for d in [Detent.PEEK, Detent.HALF, Detent.FULL]:
		var dist := absf(position.y - _detent_top(d))
		if dist < best_dist:
			best_dist = dist
			best = d
	return best


func _layout() -> void:
	var vs := get_viewport().get_visible_rect().size
	size = Vector2(vs.x, vs.y - _detent_top(Detent.FULL) + 4.0)
	position.x = 0.0
	_handle.position = Vector2.ZERO
	_handle.size = Vector2(vs.x, HANDLE_H)
	_tab_bar.position = Vector2(10.0, HANDLE_H)
	_tab_bar.size = Vector2(vs.x - 20.0, TABS_H)
	var header: HBoxContainer = get_node("Header")
	header.position = Vector2(10.0, HANDLE_H + TABS_H + 4.0)
	header.size = Vector2(vs.x - 20.0, HEADER_H)
	var content_top := HANDLE_H + TABS_H + HEADER_H + 8.0
	_scroll.position = Vector2(10.0, content_top)
	_scroll.size = Vector2(vs.x - 20.0, size.y - content_top - 12.0)


# Tabs and screens.

## A category button was pressed. A long-press arms continuous build; any
## tab switch first disarms a placement left running on the previous tab.
func _on_category_chosen(tab_id: String, long: bool) -> void:
	_disarm_placement()
	_continuous_build = long
	_select_tab(tab_id)


func _select_tab(tab_id: String) -> void:
	_current_tab = tab_id
	for id: String in _tab_buttons:
		(_tab_buttons[id] as CategoryButton).selected = id == tab_id
	_show_screen(_tab_screens.get(tab_id, _tab_root(tab_id)))


func _show_screen(screen_id: String) -> void:
	if not catalog.console_screens.has(screen_id):
		return
	_tab_screens[_current_tab] = screen_id
	var screen: UICatalog.ScreenDef = catalog.console_screens[screen_id]
	_title.text = screen.title
	_back_button.visible = screen_id != _tab_root(_current_tab)
	for child in _content.get_children():
		child.queue_free()
	for widget in screen.widgets:
		_content.add_child(_build_widget(widget))


func _build_widget(widget: UICatalog.WidgetDef) -> Control:
	match widget.type:
		"button":
			var btn := Button.new()
			btn.text = widget.label
			btn.custom_minimum_size.y = 52.0
			btn.pressed.connect(_on_widget_pressed.bind(widget))
			return btn
		"structure_grid":
			if ctx != null:
				return ConsoleWidgets.StructureGrid.new(ctx,
						_begin_placement.bind(widget))
		"unit_grid":
			if ctx != null:
				return ConsoleWidgets.UnitGrid.new(ctx)
		"queue_strip":
			if ctx != null:
				return ConsoleWidgets.QueueStrip.new(ctx)
		"alloc_sliders":
			if ctx != null:
				return ConsoleWidgets.AllocSliders.new(ctx)
		"group_roster":
			if ctx != null:
				return ConsoleWidgets.GroupRoster.new(ctx)
		"worker_dials":
			if ctx != null:
				return ConsoleWidgets.WorkerDials.new(ctx)
		"stance_picker":
			if ctx != null:
				return ConsoleWidgets.StancePicker.new(ctx)
		"minimap":
			if ctx != null:
				var mini := MinimapView.new()
				mini.sim = ctx.sim
				mini.local_player = ctx.local_player
				mini.designations = ctx.designations
				mini.mode = MinimapView.Mode.PICK \
						if widget.params.get("mode", "jump") == "pick" \
						else MinimapView.Mode.JUMP
				mini.custom_minimum_size = Vector2(320, 320)
				mini.pin_tapped.connect(_preview_at_designation)
				mini.point_tapped.connect(_on_build_point)
				return mini
		"build_targets":
			if ctx != null:
				return ConsoleWidgets.BuildTargets.new(ctx,
						_preview_at_designation, _on_build_point,
						widget.params.get("minimap_mode", "pick"))
	var label := Label.new()
	label.text = widget.label
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.modulate = Color(1, 1, 1, 0.7)
	return label


func _on_widget_pressed(widget: UICatalog.WidgetDef) -> void:
	if widget.action.begins_with("screen:"):
		_show_screen(widget.action.trim_prefix("screen:"))
		return
	# A button bound to a verb (e.g. the Rebel draw-wall verb, design_m4.md
	# §4.4): arm the viewport gesture for it through the context hook. The
	# BUILD_WALL sim path is complete; the stroke-rasterization gesture is the
	# remaining viewport wiring.
	var command: String = widget.params.get("command", "")
	if not command.is_empty() and ctx != null and ctx.arm_verb.is_valid():
		ctx.arm_verb.call(command)
		return
	if not command.is_empty():
		print("[console] verb '%s' armed (viewport gesture pending)" % command)
		return
	print("[console] '%s' tapped (no action wired yet)" % widget.label)


func _on_back() -> void:
	_disarm_placement()
	_continuous_build = false
	_show_screen(_tab_root(_current_tab))


## Cancel any build placement currently armed (ghost + confirm bar) and
## forget the pending type. Safe in structural-only mode (ctx == null).
func _disarm_placement() -> void:
	if _pending_build == -1:
		return
	_pending_build = -1
	if ctx != null and ctx.cancel_placement.is_valid():
		ctx.cancel_placement.call()


## Called by the game root once a BUILD command has been issued for a
## placement. In single-build mode this pops back to the tab root; in
## continuous mode it re-arms the same structure for another drop.
func notify_build_committed() -> void:
	if _continuous_build and _pending_build != -1 and ctx != null \
			and ctx.arm_placement.is_valid():
		ctx.arm_placement.call(_pending_build)
		return
	_disarm_placement()
	_show_screen(_tab_root(_current_tab))


# --- Build placement flow (design_m3.md §6.3) -----------------------------------


## Picking a structure arms BOTH placement paths at once: the console's
## placement screen (pins / popup) and direct viewport placement — swipe
## the console down and tap the world (design.md "The Command Console").
func _begin_placement(type_key: int, widget: UICatalog.WidgetDef) -> void:
	_pending_build = type_key
	if ctx.arm_placement.is_valid():
		ctx.arm_placement.call(type_key)
	_show_screen(widget.params.get("placement_screen", ""))


## Build at a saved location (a list row, or its pin on the minimap): auto-place
## the building at the best clear spot near the base, then open the popup
## viewport jumped there so the player can confirm in one tap or nudge it
## (design.md "The Command Console" — auto-resolve plus popup placement). With
## no build armed (the World/jump minimap) it just recenters the camera.
func _preview_at_designation(slot: int) -> void:
	var e: Variant = ctx.designations.entry(slot)
	if e == null or e["kind"] != "location":
		return
	if _pending_build == -1:
		ctx.jump_camera.call(e["x"], e["y"])
		detent = Detent.PEEK
		return
	var type_key := _pending_build
	var s := ctx.sim.catalog.sim_of(type_key)
	var site := _resolve_site(type_key, e["x"], e["y"])
	if site.x == -1:
		ctx.status.call("no vent inside influence" if s["builds_on_vent"]
				else "no clear spot near %s" % e["name"])
		return
	# Center of the resolved footprint (sim fixed): the popup re-snaps the ghost
	# under this point, landing it back on exactly these cells.
	var cx := Fixed.from_float((site.x + s["foot_w"] / 2.0) / SimGrid.PATH_SUBDIV)
	var cy := Fixed.from_float((site.y + s["foot_h"] / 2.0) / SimGrid.PATH_SUBDIV)
	_open_popup(type_key, cx, cy)
	ctx.status.call("placing %s near %s — confirm or drag" % [
			ctx.label_of(type_key), e["name"]])


## A bare map point (minimap tap): pick mode opens the popup for hand placement
## at that point; jump mode (no build armed) just recenters the camera there.
func _on_build_point(x: int, y: int) -> void:
	if _pending_build == -1:
		ctx.jump_camera.call(x, y)
		detent = Detent.PEEK
		return
	_open_popup(_pending_build, x, y)


## Hand off to the popup viewport: drop the console build state and the direct
## viewport ghost, then open the popup centered on (x, y) (sim fixed). The popup
## owns confirm/cancel from here; notify_build_committed returns the console.
func _open_popup(type_key: int, x: int, y: int) -> void:
	_pending_build = -1
	_on_back()
	if ctx.cancel_placement.is_valid():
		ctx.cancel_placement.call() # the popup's ghost takes over
	ctx.open_placement.call(type_key, x, y)


## The footprint cell (cx, cy) to auto-place `type_key` near a pin (sim fixed):
## the nearest untaken vent for vent-bound structures, else a clearance-aware
## spiral search. Returns (-1, -1) when nothing suitable is nearby.
func _resolve_site(type_key: int, px: int, py: int) -> Vector2i:
	var sim := ctx.sim
	var s := sim.catalog.sim_of(type_key)
	if s["builds_on_vent"]:
		return _nearest_vent_site(type_key, px, py)
	var w: int = s["foot_w"]
	var h: int = s["foot_h"]
	return _spiral_search(type_key, w, h,
			sim.grid.cell_of(px) - w / 2, sim.grid.cell_of(py) - h / 2)


## Nearest untaken vent to the pin satisfying the territory requirement.
func _nearest_vent_site(type_key: int, px: int, py: int) -> Vector2i:
	var sim := ctx.sim
	var s := sim.catalog.sim_of(type_key)
	var found := Vector2i(-1, -1)
	var best_d2 := 0
	for v: Dictionary in sim.vents():
		if v["taken"]:
			continue
		var vcx: int = v["cx"]
		var vcy: int = v["cy"]
		if s["requires_territory"] and not sim.territory_covers(
				ctx.local_player,
				vcx * SimGrid.CELL + v["w"] * SimGrid.CELL / 2,
				vcy * SimGrid.CELL + v["h"] * SimGrid.CELL / 2):
			continue
		var dx: int = Fixed.to_int(px) - (vcx + v["w"] / 2) / SimGrid.PATH_SUBDIV
		var dy: int = Fixed.to_int(py) - (vcy + v["h"] / 2) / SimGrid.PATH_SUBDIV
		var d2 := dx * dx + dy * dy
		if found.x == -1 or d2 < best_d2:
			best_d2 = d2
			found = Vector2i(vcx, vcy)
	return found


## Spiral out from the pin for an auto-placement cell. The player asked for
## breathing room, so a footprint with a clear `CLEARANCE`-cell margin on all
## sides (no pathing choke) wins; inside-influence is preferred at equal
## distance (cheaper for the Hive). Falls back to the nearest merely-legal
## footprint when nothing roomy is in range. Legality is judged on what the
## player can see — fogged cells count as free; the sim settles it at landing.
func _spiral_search(type_key: int, w: int, h: int, c0x: int, c0y: int) -> Vector2i:
	var requires: bool = ctx.sim.catalog.sim_of(type_key)["requires_territory"]
	var tight := Vector2i(-1, -1) # nearest legal footprint without the clear ring
	for r in range(0, 25):
		var clear := Vector2i(-1, -1)
		var clear_inside := Vector2i(-1, -1)
		for pos in _ring_positions(c0x, c0y, r):
			if not _predict_legal(type_key, pos.x, pos.y, w, h):
				continue
			var inside := _site_inside(type_key, pos.x, pos.y, w, h)
			if requires and not inside:
				continue # requires_territory builds only place inside influence
			if tight.x == -1:
				tight = pos
			if _predict_clear(type_key, pos.x, pos.y, w, h, CLEARANCE):
				if inside and clear_inside.x == -1:
					clear_inside = pos
				elif clear.x == -1:
					clear = pos
		# A clear spot at this radius is the nearest one; prefer inside influence.
		if clear_inside.x != -1:
			return clear_inside
		if clear.x != -1:
			return clear
	return tight


## True if the footprint's center sits inside the player's territory influence.
func _site_inside(type_key: int, cx: int, cy: int, w: int, h: int) -> bool:
	return ctx.sim.territory_covers(ctx.local_player,
			cx * SimGrid.CELL + w * SimGrid.CELL / 2,
			cy * SimGrid.CELL + h * SimGrid.CELL / 2)


func _ring_positions(cx: int, cy: int, r: int) -> Array[Vector2i]:
	var result: Array[Vector2i] = []
	if r == 0:
		result.append(Vector2i(cx, cy))
		return result
	for x in range(cx - r, cx + r + 1):
		result.append(Vector2i(x, cy - r))
		result.append(Vector2i(x, cy + r))
	for y in range(cy - r + 1, cy + r):
		result.append(Vector2i(cx - r, y))
		result.append(Vector2i(cx + r, y))
	return result


## Visible-and-blocked fails; fog counts as free (the player's bet).
func _predict_legal(type_key: int, cx: int, cy: int, w: int, h: int) -> bool:
	var sim := ctx.sim
	if cx < 0 or cy < 0 or cx + w > sim.grid.width or cy + h > sim.grid.height:
		return false
	for fy in range(cy, cy + h):
		for fx in range(cx, cx + w):
			if sim.is_cell_visible(ctx.local_player, fx, fy) \
					and sim.grid.is_blocked(fx, fy):
				return false
	return true


## Like _predict_legal but also requires a `margin`-cell ring around the
## footprint to be in-bounds and clear, so the building leaves a pathing lane on
## every side. Fog counts as free; only visibly-blocked cells fail.
func _predict_clear(type_key: int, cx: int, cy: int, w: int, h: int,
		margin: int) -> bool:
	var sim := ctx.sim
	var x0 := cx - margin
	var y0 := cy - margin
	var x1 := cx + w + margin
	var y1 := cy + h + margin
	if x0 < 0 or y0 < 0 or x1 > sim.grid.width or y1 > sim.grid.height:
		return false
	for fy in range(y0, y1):
		for fx in range(x0, x1):
			if sim.is_cell_visible(ctx.local_player, fx, fy) \
					and sim.grid.is_blocked(fx, fy):
				return false
	return true


func _tab_root(tab_id: String) -> String:
	for tab in catalog.console_tabs:
		if tab.id == tab_id:
			return tab.screen
	return ""


func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), Color(0.07, 0.08, 0.1, 0.97))


class Handle:
	extends TouchButton
	## Grab bar at the console's top edge. When the console is at peek this
	## sits at the bottom of the screen, so "swipe up from the bottom" and
	## "drag the console" are the same gesture on the same control.

	var console: ConsoleView

	func _press_started() -> void:
		console.begin_drag(pointer_pos.y)

	func _pointer_moved() -> void:
		console.drag_to(pointer_pos.y)

	func _released(held_for: float) -> void:
		console.end_drag(held_for)

	func _draw() -> void:
		draw_rect(Rect2(Vector2.ZERO, size), Color(0.12, 0.14, 0.17, 1.0))
		var grip := Vector2(56.0, 5.0)
		draw_rect(Rect2((size - grip) * 0.5, grip), Color(1, 1, 1, 0.45))


class CategoryButton:
	extends TouchButton
	## Round, pill-shaped category selector (replacing flat tabs): tap to
	## switch to the category, long-press to flag continuous build. What the
	## category *is* stays catalog data; this control only renders and reports.

	signal chosen(tab_id: String, long: bool)

	const HEIGHT := 44.0
	const LONG_TIME := 0.4
	const FONT_SIZE := 15

	var tab_id := ""
	var label := ""
	var selected := false:
		set(value):
			selected = value
			queue_redraw()

	var _long := false


	func setup(p_tab_id: String, p_label: String) -> void:
		tab_id = p_tab_id
		label = p_label
		var w := ThemeDB.fallback_font.get_string_size(
				label, HORIZONTAL_ALIGNMENT_CENTER, -1, FONT_SIZE).x
		custom_minimum_size = Vector2(maxf(HEIGHT, w + 30.0), HEIGHT)


	func _press_started() -> void:
		_long = false


	func _held(time: float) -> void:
		if not _long and time >= LONG_TIME:
			_long = true
			Input.vibrate_handheld(20) # haptic cue that continuous build armed


	func _released(_held_for: float) -> void:
		# Ignore releases dragged off the pill (e.g. a stray swipe).
		if get_global_rect().has_point(pointer_pos):
			chosen.emit(tab_id, _long)


	func _draw() -> void:
		var sb := StyleBoxFlat.new()
		sb.bg_color = Color(0.22, 0.45, 0.62, 0.95) if selected \
				else Color(0.16, 0.18, 0.22, 0.9)
		if is_pressed_now():
			sb.bg_color = sb.bg_color.lightened(0.12)
		sb.set_corner_radius_all(int(size.y / 2.0))
		sb.border_width_bottom = 2
		sb.border_width_top = 2
		sb.border_width_left = 2
		sb.border_width_right = 2
		sb.border_color = Color(1, 1, 1, 0.55 if selected else 0.2)
		draw_style_box(sb, Rect2(Vector2.ZERO, size))
		var font := ThemeDB.fallback_font
		var tw := font.get_string_size(label, HORIZONTAL_ALIGNMENT_CENTER,
				-1, FONT_SIZE).x
		draw_string(font, Vector2((size.x - tw) / 2.0, size.y / 2.0 + FONT_SIZE * 0.35),
				label, HORIZONTAL_ALIGNMENT_LEFT, -1, FONT_SIZE, Color.WHITE)
