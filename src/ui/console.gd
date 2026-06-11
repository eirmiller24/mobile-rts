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

const HANDLE_H := 30.0
const TABS_H := 48.0
const HEADER_H := 40.0
const FLICK_TIME := 0.35
const FLICK_DISTANCE := 48.0

var catalog: UICatalog
var detent := Detent.PEEK

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


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP

	_handle = Handle.new()
	_handle.console = self
	add_child(_handle)

	_tab_bar = HBoxContainer.new()
	_tab_bar.add_theme_constant_override("separation", 4)
	add_child(_tab_bar)
	var group := ButtonGroup.new()
	for tab in catalog.console_tabs:
		var btn := Button.new()
		btn.text = tab.label
		btn.toggle_mode = true
		btn.button_group = group
		btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		btn.custom_minimum_size.y = TABS_H - 8.0
		btn.pressed.connect(_select_tab.bind(tab.id))
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
		var first := catalog.console_tabs[0]
		_tab_buttons[first.id].button_pressed = true
		_select_tab(first.id)


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


func drag_to(pointer_y: float) -> void:
	position.y = clampf(pointer_y - _grab_offset,
			_detent_top(Detent.FULL), _detent_top(Detent.PEEK))


func end_drag(held_for: float) -> void:
	_dragging = false
	var travelled := position.y - _drag_start_top
	if held_for < FLICK_TIME and absf(travelled) > FLICK_DISTANCE:
		# A flick moves one detent in the swipe direction.
		if travelled < 0.0:
			detent = Detent.HALF if detent == Detent.PEEK else Detent.FULL
		else:
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

func _select_tab(tab_id: String) -> void:
	_current_tab = tab_id
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
		_:
			var label := Label.new()
			label.text = widget.label
			label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
			label.modulate = Color(1, 1, 1, 0.7)
			return label


func _on_widget_pressed(widget: UICatalog.WidgetDef) -> void:
	if widget.action.begins_with("screen:"):
		_show_screen(widget.action.trim_prefix("screen:"))
	else:
		print("[console] '%s' tapped (no action wired yet)" % widget.label)


func _on_back() -> void:
	_show_screen(_tab_root(_current_tab))


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
