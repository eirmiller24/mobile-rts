class_name Hud
extends CanvasLayer
## Assembles the in-game UI from a UICatalog: side button column on the
## right, reselect in the bottom-left corner, lasso overlay, selection
## status. Pure construction — every binding comes from the catalog.

signal command_chosen(command_id: String)

var catalog: UICatalog
## Set by the game root before add_child, like catalog.
var designations: Designations
var ctx: GameUIContext
var buttons: Array[RadialButton] = []
var reselect: ReselectButton
var designation_button: DesignationButton
var chips: DesignationChips
var lasso_overlay: LassoOverlay
var status_label: Label
var console: ConsoleView

var _readout: Label
var _readout_accum := 0.0


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

	var column := VBoxContainer.new()
	var separation := 28
	column.add_theme_constant_override("separation", separation)
	add_child(column)
	var column_width := 0.0
	var column_height := 0.0
	for def in catalog.side_buttons:
		var btn := RadialButton.new()
		btn.setup(catalog, def)
		btn.command_chosen.connect(_on_command_chosen)
		column.add_child(btn)
		buttons.append(btn)
		column_width = maxf(column_width, btn.custom_minimum_size.x)
		column_height += btn.custom_minimum_size.y
	if designations != null:
		designation_button = DesignationButton.new()
		designation_button.setup(designations)
		column.add_child(designation_button)
		column_width = maxf(column_width, designation_button.custom_minimum_size.x)
		column_height += designation_button.custom_minimum_size.y + separation
	column_height += separation * maxi(0, buttons.size() - 1)
	# Pin to the right edge, vertically centered, regardless of window size.
	column.anchor_left = 1.0
	column.anchor_right = 1.0
	column.anchor_top = 0.5
	column.anchor_bottom = 0.5
	column.offset_right = -16.0
	column.offset_left = -16.0 - column_width
	column.offset_top = -column_height / 2.0
	column.offset_bottom = column_height / 2.0

	reselect = ReselectButton.new()
	reselect.setup(catalog)
	var rs := reselect.custom_minimum_size
	reselect.anchor_left = 0.0
	reselect.anchor_right = 0.0
	reselect.anchor_top = 1.0
	reselect.anchor_bottom = 1.0
	reselect.offset_left = 16.0
	reselect.offset_right = 16.0 + rs.x
	reselect.offset_top = -16.0 - rs.y
	reselect.offset_bottom = -16.0
	add_child(reselect)

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
	if designation_button != null \
			and designation_button.get_global_rect().has_point(point):
		return true
	if chips != null and chips._row != null \
			and chips._row.get_global_rect().has_point(point):
		return true
	if point.y >= console.position.y: # console spans the full width
		return true
	return reselect.get_global_rect().has_point(point)


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
