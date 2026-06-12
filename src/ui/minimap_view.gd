class_name MinimapView
extends Control
## Console-embedded minimap (design_m3.md §6.2): top-down low-res render —
## ground, resource nodes (always drawn; the map is public knowledge),
## influence tint, designation pins, entity dots by faction on visible
## tiles only, fog dimming elsewhere. Redraws at ~4 Hz from sim batch
## reads, plus immediately on open.
##
## Input modes: JUMP (tap -> owner centers the main camera and closes the
## console) and PICK (tap -> return a map position to the requesting flow,
## used by Build). Taps near a designation pin report the pin instead.

enum Mode { JUMP, PICK }

## Tap on open ground (sim fixed coords).
signal point_tapped(x: int, y: int)
## Tap on (near) a location-designation pin.
signal pin_tapped(slot: int)

const REFRESH_INTERVAL := 0.25
const PIN_TAP_RADIUS := 18.0

var sim: Sim
var local_player := 1
var designations: Designations
var mode := Mode.JUMP

const COLOR_GROUND := Color(0.16, 0.19, 0.16)
const COLOR_FOG := Color(0.07, 0.08, 0.09)
const COLOR_ALLOY := Color(0.93, 0.83, 0.21)
const COLOR_FLUX := Color(0.49, 0.34, 0.76)
const COLOR_OWN := Color(0.35, 0.81, 0.94)
const COLOR_ENEMY := Color(0.88, 0.25, 0.21)
const COLOR_INFLUENCE := Color(0.2, 0.7, 0.3, 0.25)
const COLOR_PIN := Color(1.0, 0.85, 0.4)

var _texture: ImageTexture
var _since_refresh := 999.0


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	custom_minimum_size = Vector2(256, 256)


func _process(delta: float) -> void:
	if not is_visible_in_tree():
		return
	_since_refresh += delta
	if _since_refresh >= REFRESH_INTERVAL:
		_since_refresh = 0.0
		_rebuild_texture()
		queue_redraw()


## The square the map occupies inside this control (centered, fitted).
func map_rect() -> Rect2:
	var side := minf(size.x, size.y)
	return Rect2((size - Vector2(side, side)) * 0.5, Vector2(side, side))


func _rebuild_texture() -> void:
	if sim == null:
		return
	var w := sim.grid.tiles_w
	var h := sim.grid.tiles_h
	var img := Image.create(w, h, false, Image.FORMAT_RGB8)
	var fog := sim.vision_of(local_player)
	for ty in h:
		for tx in w:
			var visible := not fog.is_empty() and fog[ty * w + tx] == 1
			img.set_pixel(tx, ty, COLOR_GROUND if visible else COLOR_FOG)
	# Entities: resource nodes always; own entities always; others only on
	# visible tiles (two-state fog, §4.4).
	for id in sim.entities:
		var e: SimEntity = sim.entities[id]
		if e.hp <= 0:
			continue
		var tx := clampi(Fixed.to_int(e.x), 0, w - 1)
		var ty := clampi(Fixed.to_int(e.y), 0, h - 1)
		var color: Color
		if e.is_resource():
			color = COLOR_ALLOY if e.resource_kind == CatalogSchema.ResourceKind.ALLOY \
					else COLOR_FLUX
		elif e.player == local_player:
			color = COLOR_OWN
		elif sim.is_tile_visible(local_player, tx, ty):
			color = COLOR_ENEMY
		else:
			continue
		_stamp(img, e, tx, ty, color)
	_texture = ImageTexture.create_from_image(img)


## Structures/resources fill their footprint tiles; units are one pixel.
func _stamp(img: Image, e: SimEntity, tx: int, ty: int, color: Color) -> void:
	if e.is_unit():
		img.set_pixel(tx, ty, color)
		return
	var t0x := e.foot_x / SimGrid.PATH_SUBDIV
	var t0y := e.foot_y / SimGrid.PATH_SUBDIV
	var t1x := (e.foot_x + e.foot_w - 1) / SimGrid.PATH_SUBDIV
	var t1y := (e.foot_y + e.foot_h - 1) / SimGrid.PATH_SUBDIV
	for y in range(maxi(0, t0y), mini(img.get_height() - 1, t1y) + 1):
		for x in range(maxi(0, t0x), mini(img.get_width() - 1, t1x) + 1):
			img.set_pixel(x, y, color)


func _draw() -> void:
	var rect := map_rect()
	draw_rect(Rect2(Vector2.ZERO, size), Color(0.05, 0.06, 0.07))
	if _texture == null:
		_rebuild_texture()
	if _texture != null:
		draw_texture_rect(_texture, rect, false)
	if sim == null:
		return
	# Influence tint.
	for circle: Array in sim.flagged_aura_circles(local_player, "territory"):
		draw_circle(_to_px(circle[0], circle[1], rect),
				Fixed.to_float(circle[2]) * rect.size.x / sim.grid.tiles_w,
				COLOR_INFLUENCE)
	# Designation pins (highlighted when picking a build site).
	if designations != null:
		for o: Dictionary in designations.locations():
			var e: Dictionary = o["entry"]
			var p := _to_px(e["x"], e["y"], rect)
			var r := 6.0 if mode == Mode.PICK else 4.0
			draw_circle(p, r, COLOR_PIN)
			draw_arc(p, r + 2.0, 0.0, TAU, 16, Color(0, 0, 0, 0.6), 1.5)
			if mode == Mode.PICK:
				draw_string(ThemeDB.fallback_font, p + Vector2(-40.0, -8.0),
						e["name"], HORIZONTAL_ALIGNMENT_CENTER, 80.0, 11, COLOR_PIN)
	draw_rect(rect, Color(1, 1, 1, 0.25), false, 1.0)


func _to_px(x: int, y: int, rect: Rect2) -> Vector2:
	return rect.position + Vector2(
			Fixed.to_float(x) / sim.grid.tiles_w * rect.size.x,
			Fixed.to_float(y) / sim.grid.tiles_h * rect.size.y)


func _gui_input(event: InputEvent) -> void:
	var pos := Vector2.ZERO
	var tapped := false
	if event is InputEventScreenTouch and event.pressed:
		pos = event.position
		tapped = true
	elif event is InputEventMouseButton and event.pressed \
			and event.button_index == MOUSE_BUTTON_LEFT:
		pos = event.position
		tapped = true
	if not tapped:
		return
	accept_event()
	var rect := map_rect()
	if not rect.has_point(pos):
		return
	# Pins win over bare ground when close enough.
	if designations != null:
		for o: Dictionary in designations.locations():
			var e: Dictionary = o["entry"]
			if _to_px(e["x"], e["y"], rect).distance_to(pos) <= PIN_TAP_RADIUS:
				pin_tapped.emit(o["slot"])
				return
	var rel := (pos - rect.position) / rect.size
	point_tapped.emit(
			Fixed.from_float(rel.x * sim.grid.tiles_w),
			Fixed.from_float(rel.y * sim.grid.tiles_h))
