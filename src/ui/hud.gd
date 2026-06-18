class_name Hud
extends CanvasLayer
## Assembles the in-game UI from a UICatalog: side button column on the
## right (verbs, abilities, the held control modifier), lasso overlay,
## selection status. Pure construction — every binding comes from the catalog.

signal command_chosen(command_id: String)

var catalog: UICatalog
## Set by the game root before add_child, like catalog.
var designations: Designations
var ctx: GameUIContext
var buttons: Array[RadialButton] = []
var control_button: ControlButton
var chips: DesignationChips
var locations_button: LocationsButton
var lasso_overlay: LassoOverlay
var status_label: Label
var console: ConsoleView

var _readout: Label
var _readout_accum := 0.0
## Extra controls (registered by the game root) that should block viewport
## gestures while visible — e.g. the placement confirm bar.
var extra_occluders: Array[Control] = []


## HUD resource readout (design_m3.md §6.7): floored balances + derived
## bandwidth, labels skinned by the UI catalog.
func _process(delta: float) -> void:
	if _readout == null or ctx == null:
		return
	_readout_accum += delta
	if _readout_accum < 0.25:
		return
	_readout_accum = 0.0
	var res := ctx.sim.resources_of(ctx.local_player)
	var bw := ctx.sim.bandwidth_of(ctx.local_player)
	_readout.text = "%s %d    %s %d    %s %d/%d" % [
			catalog.hud_labels["alloy"], res["alloy"],
			catalog.hud_labels["flux"], res["flux"],
			catalog.hud_labels["bandwidth"], bw["used"], bw["provided"]]


func _ready() -> void:
	lasso_overlay = LassoOverlay.new()
	lasso_overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	lasso_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(lasso_overlay)

	# Right-edge command buttons (move / abilities). They sit at fixed screen
	# fractions rather than a centered stack, so the thumb finds each in the
	# same place on any window size; with the two command buttons that lands
	# them on 1/3 and 2/3 of the height (even spacing now that the control
	# modifier lives in the bottom-left corner instead of stacking with them).
	var right_controls: Array[Control] = []
	for def in catalog.side_buttons:
		var btn := RadialButton.new()
		btn.setup(catalog, def)
		btn.command_chosen.connect(_on_command_chosen)
		add_child(btn)
		buttons.append(btn)
		right_controls.append(btn)
	for i in right_controls.size():
		_pin_right(right_controls[i], float(i + 1) / float(right_controls.size() + 1))
	# The held control modifier always exists (its mechanics are engine code,
	# not catalog bindings). It lives in the bottom-left corner so the player
	# can hold it with the left thumb while the right thumb works the move /
	# attack buttons — e.g. ctrl+move to queue a waypoint, which is awkward
	# when both live on the same edge (design.md "The control button").
	control_button = ControlButton.new()
	control_button.setup()
	add_child(control_button)
	_pin_bottom_left(control_button)

	status_label = Label.new()
	status_label.set_anchors_preset(Control.PRESET_TOP_LEFT)
	status_label.position = Vector2(16, 12)
	status_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(status_label)

	if designations != null:
		chips = DesignationChips.new()
		chips.designations = designations
		chips.offset_top = 8.0
		chips.offset_bottom = 8.0 + DesignationChips.CHIP_H
		add_child(chips)

		# One Locations dropdown, toward the middle/right of the top bar,
		# replacing per-pin chips.
		locations_button = LocationsButton.new()
		locations_button.setup(designations)
		locations_button.size = locations_button.custom_minimum_size
		locations_button.anchor_left = 0.66
		locations_button.anchor_right = 0.66
		locations_button.anchor_top = 0.0
		locations_button.anchor_bottom = 0.0
		locations_button.offset_left = 0.0
		locations_button.offset_right = locations_button.custom_minimum_size.x
		locations_button.offset_top = 44.0
		locations_button.offset_bottom = 44.0 + LocationsButton.HEIGHT
		add_child(locations_button)

	if ctx != null:
		_readout = Label.new()
		_readout.anchor_left = 1.0
		_readout.anchor_right = 1.0
		_readout.offset_left = -360.0
		_readout.offset_right = -16.0
		_readout.offset_top = 12.0
		_readout.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		_readout.mouse_filter = Control.MOUSE_FILTER_IGNORE
		add_child(_readout)

	# Last child = on top of everything else in the layer.
	console = ConsoleView.new()
	console.catalog = catalog
	console.ctx = ctx
	add_child(console)


## A held side button acts as a command modifier for a simultaneous viewport
## tap. Returns "" when no button is held; marks the button used so its
## release doesn't also choose the command.
func take_modifier() -> String:
	for btn in buttons:
		if btn.is_pressed_now():
			btn.mark_used()
			return btn.live_command()
	return ""


## True while the control modifier is held — the touch-native Ctrl. Gestures
## consult this to queue orders and add/remove from the selection rather than
## replace it (design.md "The control button").
func control_held() -> bool:
	return control_button != null and control_button.is_pressed_now()


## Highlight the button that owns the armed (awaiting-target) command;
## "" clears all highlights. Armed state itself lives in the controller.
func set_armed(command_id: String) -> void:
	for btn in buttons:
		var owns := not command_id.is_empty() \
				and (btn.def.default_command == command_id
					or command_id in btn.def.radial.values())
		btn.set_armed_display(command_id if owns else "")


## True if a viewport gesture starting at this point would land on UI.
## Needed because raw touch events can leak past GUI consumption when
## touch/mouse emulation duplicates them.
func is_point_on_ui(point: Vector2) -> bool:
	for btn in buttons:
		if btn.get_global_rect().has_point(point):
			return true
	if control_button != null \
			and control_button.get_global_rect().has_point(point):
		return true
	if chips != null and chips.covers_point(point):
		return true
	if locations_button != null and locations_button.covers_point(point):
		return true
	if point.y >= console.position.y: # console spans the full width
		return true
	for c in extra_occluders:
		if c.visible and c.get_global_rect().has_point(point):
			return true
	return false


## Pin a control against the right edge, vertically centered on `frac` of
## the viewport height (0..1).
func _pin_right(c: Control, frac: float) -> void:
	var sz := c.custom_minimum_size
	c.size = sz
	c.anchor_left = 1.0
	c.anchor_right = 1.0
	c.anchor_top = frac
	c.anchor_bottom = frac
	c.offset_right = -16.0
	c.offset_left = -16.0 - sz.x
	c.offset_top = -sz.y / 2.0
	c.offset_bottom = sz.y / 2.0


## Pin a control to the bottom-left corner. It is lifted just enough that the
## button's lower radial petal (the deselect-all swipe target, which sits
## PETAL_OFFSET below center) stays on screen and tappable.
func _pin_bottom_left(c: Control) -> void:
	var sz := c.custom_minimum_size
	c.size = sz
	var lift := ControlButton.PETAL_OFFSET + ControlButton.PETAL_RADIUS \
			- sz.y / 2.0 + 12.0
	c.anchor_left = 0.0
	c.anchor_right = 0.0
	c.anchor_top = 1.0
	c.anchor_bottom = 1.0
	c.offset_left = 16.0
	c.offset_right = 16.0 + sz.x
	c.offset_bottom = -lift
	c.offset_top = -lift - sz.y


func set_status(text: String) -> void:
	status_label.text = text


func _on_command_chosen(_source: RadialButton, command_id: String) -> void:
	command_chosen.emit(command_id)


class LassoOverlay:
	extends Control
	## Draws the in-progress lasso path fed by the selection controller.

	var points := PackedVector2Array()

	func set_points(p: PackedVector2Array) -> void:
		points = p
		queue_redraw()

	func _draw() -> void:
		if points.size() < 2:
			return
		draw_polyline(points, Color(0.4, 0.9, 0.6, 0.8), 3.0, true)
		draw_line(points[points.size() - 1], points[0],
				Color(0.4, 0.9, 0.6, 0.35), 2.0, true)
