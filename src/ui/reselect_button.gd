class_name ReselectButton
extends TouchButton
## Corner button: tap re-grabs the last selected group; long-press toggles
## the auto-deselect-after-order behavior (design.md "Controls").

signal reselect_requested
signal auto_deselect_toggled(enabled: bool)

const RADIUS := 38.0

var label := "Re"
var hold_time_threshold := 0.5
var auto_deselect := true

var _toggled_this_press := false


func setup(catalog: UICatalog) -> void:
	label = catalog.reselect_label
	hold_time_threshold = catalog.reselect_hold_time
	custom_minimum_size = Vector2.ONE * (RADIUS * 2.0 + 12.0)


func _press_started() -> void:
	_toggled_this_press = false


func _held(time: float) -> void:
	if not _toggled_this_press and time >= hold_time_threshold:
		_toggled_this_press = true
		auto_deselect = not auto_deselect
		auto_deselect_toggled.emit(auto_deselect)
		queue_redraw()


func _released(_held_for: float) -> void:
	if not _toggled_this_press:
		reselect_requested.emit()


func _draw() -> void:
	var c := size * 0.5
	var base_color := Color(0.15, 0.17, 0.2, 0.85)
	if not auto_deselect:
		base_color = Color(0.1, 0.35, 0.2, 0.9) # sticky-selection mode
	if is_pressed_now():
		base_color = base_color.lightened(0.15)
	draw_circle(c, RADIUS, base_color)
	draw_arc(c, RADIUS, 0.0, TAU, 48, Color(1, 1, 1, 0.5), 2.0)
	var font := ThemeDB.fallback_font
	draw_string(font, c + Vector2(-60.0, 5.0), label,
			HORIZONTAL_ALIGNMENT_CENTER, 120.0, 14, Color.WHITE)
	if not auto_deselect:
		draw_string(font, c + Vector2(-60.0, 22.0), "sticky",
				HORIZONTAL_ALIGNMENT_CENTER, 120.0, 10, Color(0.7, 1, 0.8))
