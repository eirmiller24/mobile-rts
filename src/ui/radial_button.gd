class_name RadialButton
extends TouchButton
## The core button idiom (design.md "Side buttons"): tap = default command,
## hold = 4 options on cardinal directions, swipe to pick. While held the
## button acts as a command modifier. On release it reports the chosen verb;
## the selection controller owns what happens next (execute now vs await a
## target), because command grammar is subject-verb-object and only the
## controller knows the subject.
##
## Bindings come entirely from the UI catalog; this control never knows
## what its commands mean.

signal command_chosen(button: RadialButton, command_id: String)

const HOLD_TIME := 0.25
const RADIUS := 44.0
const DEAD_ZONE := 48.0
const PETAL_OFFSET := 104.0
const PETAL_RADIUS := 34.0
const DIRECTIONS := {
	"up": Vector2.UP,
	"right": Vector2.RIGHT,
	"down": Vector2.DOWN,
	"left": Vector2.LEFT,
}

var catalog: UICatalog
var def: UICatalog.ButtonDef

var _radial_open := false
## Command highlighted as awaiting a target; set by the HUD, not by this
## button — arming is the controller's decision.
var _armed_display := ""
var _used_while_held := false


func setup(p_catalog: UICatalog, p_def: UICatalog.ButtonDef) -> void:
	catalog = p_catalog
	def = p_def
	custom_minimum_size = Vector2.ONE * (RADIUS * 2.0 + 12.0)


## Command this button represents right now while held (modifier behavior).
func live_command() -> String:
	if not is_pressed_now():
		return ""
	if _radial_open:
		return _command_under_pointer()
	return def.default_command


func set_armed_display(command_id: String) -> void:
	_armed_display = command_id
	queue_redraw()


## Called when the held command was used as a modifier, so releasing the
## button afterwards doesn't also arm a one-shot.
func mark_used() -> void:
	_used_while_held = true


func _press_started() -> void:
	_radial_open = false
	_used_while_held = false


func _pointer_moved() -> void:
	if _radial_open:
		queue_redraw()


func _held(time: float) -> void:
	if not _radial_open and time >= HOLD_TIME:
		_radial_open = true
		queue_redraw()


func _released(_held_for: float) -> void:
	var cmd := _command_under_pointer() if _radial_open else def.default_command
	_radial_open = false
	if _used_while_held:
		_used_while_held = false
		return
	command_chosen.emit(self, cmd)


func _command_under_pointer() -> String:
	var v := pointer_pos - center()
	if v.length() < DEAD_ZONE:
		return def.default_command
	var dir: String
	if absf(v.x) > absf(v.y):
		dir = "right" if v.x > 0.0 else "left"
	else:
		dir = "down" if v.y > 0.0 else "up"
	return def.radial.get(dir, def.default_command)


func _draw() -> void:
	var c := size * 0.5
	var shown := _armed_display if not _armed_display.is_empty() \
			else def.default_command
	var base_color := Color(0.15, 0.17, 0.2, 0.85)
	if not _armed_display.is_empty():
		base_color = catalog.command(_armed_display).color.darkened(0.4)
	elif is_pressed_now():
		base_color = Color(0.25, 0.28, 0.33, 0.9)
	draw_circle(c, RADIUS, base_color)
	draw_arc(c, RADIUS, 0.0, TAU, 48, Color(1, 1, 1, 0.5), 2.0)
	_draw_label(c, catalog.command(shown).label, Color.WHITE)

	if _radial_open:
		var live := _command_under_pointer()
		for dir in def.radial:
			var cmd: String = def.radial[dir]
			var pc: Vector2 = c + DIRECTIONS[dir] * PETAL_OFFSET
			var color := catalog.command(cmd).color
			var fill := color.darkened(0.55)
			fill.a = 0.9
			if cmd == live:
				fill = color
			draw_circle(pc, PETAL_RADIUS, fill)
			draw_arc(pc, PETAL_RADIUS, 0.0, TAU, 40, Color(1, 1, 1, 0.6), 2.0)
			_draw_label(pc, catalog.command(cmd).label, Color.WHITE)


func _draw_label(at: Vector2, text: String, color: Color) -> void:
	var font := ThemeDB.fallback_font
	draw_string(font, at + Vector2(-60.0, 5.0), text,
			HORIZONTAL_ALIGNMENT_CENTER, 120.0, 14, color)
