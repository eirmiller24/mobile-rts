class_name LocationsButton
extends TouchButton
## A single top-bar button that collects every designated location
## (design_m3.md §6.1) behind one dropdown, instead of giving each pin its
## own chip. Hold (or tap) to drop the list down; tap a row to jump the
## camera there. The list *contents* come from the designations store; this
## control only renders and reports the chosen slot.

signal location_selected(slot: int)

const HEIGHT := 40.0
const FONT_SIZE := 16
const HOLD_TIME := 0.25
const ROW_H := 40.0
const PANEL_W := 200.0

var designations: Designations

var _open := false
var _panel: PanelContainer
var _list: VBoxContainer
var _opened_by_hold := false


func setup(p_designations: Designations) -> void:
	designations = p_designations
	custom_minimum_size = Vector2(150, HEIGHT)
	_panel = PanelContainer.new()
	_panel.visible = false
	_panel.position = Vector2(0, HEIGHT + 4.0)
	_panel.custom_minimum_size.x = PANEL_W
	add_child(_panel)
	_list = VBoxContainer.new()
	_list.add_theme_constant_override("separation", 4)
	_panel.add_child(_list)
	designations.changed.connect(func() -> void:
		if _open:
			_rebuild_list())


func _press_started() -> void:
	_opened_by_hold = false


func _held(time: float) -> void:
	if not _open and time >= HOLD_TIME:
		_opened_by_hold = true
		_set_open(true)


func _released(_held_for: float) -> void:
	# A hold has already opened the list; a plain tap toggles it.
	if not _opened_by_hold and get_global_rect().has_point(pointer_pos):
		_set_open(not _open)


func _set_open(open: bool) -> void:
	_open = open
	_panel.visible = open
	if open:
		_rebuild_list()
	queue_redraw()


func _rebuild_list() -> void:
	for child in _list.get_children():
		child.queue_free()
	var locations := designations.locations()
	if locations.is_empty():
		var empty := Label.new()
		empty.text = "No locations pinned"
		empty.add_theme_font_size_override("font_size", FONT_SIZE - 2)
		empty.modulate = Color(1, 1, 1, 0.6)
		_list.add_child(empty)
		return
	for o: Dictionary in locations:
		var row := Button.new()
		row.custom_minimum_size = Vector2(PANEL_W, ROW_H)
		row.add_theme_font_size_override("font_size", FONT_SIZE)
		row.add_theme_color_override("font_color", Color(1.0, 0.9, 0.7))
		row.text = o["entry"]["name"]
		var slot: int = o["slot"]
		row.pressed.connect(func() -> void:
			location_selected.emit(slot)
			_set_open(false))
		_list.add_child(row)


## True when a point lands on the button or its open dropdown — the HUD
## uses this so taps on the list don't fall through to the viewport.
func covers_point(point: Vector2) -> bool:
	if get_global_rect().has_point(point):
		return true
	return _open and _panel.get_global_rect().has_point(point)


func _draw() -> void:
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.22, 0.4, 0.5, 0.95) if _open else Color(0.16, 0.18, 0.22, 0.9)
	if is_pressed_now():
		sb.bg_color = sb.bg_color.lightened(0.12)
	sb.set_corner_radius_all(int(HEIGHT / 2.0))
	draw_style_box(sb, Rect2(Vector2.ZERO, Vector2(size.x, HEIGHT)))
	var count := designations.locations().size()
	var font := ThemeDB.fallback_font
	var text := "Locations (%d) ▾" % count
	var tw := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, FONT_SIZE).x
	draw_string(font, Vector2((size.x - tw) / 2.0, HEIGHT / 2.0 + FONT_SIZE * 0.35),
			text, HORIZONTAL_ALIGNMENT_LEFT, -1, FONT_SIZE, Color.WHITE)
