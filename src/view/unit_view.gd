class_name UnitView
extends Node3D
## Visualization of one sim entity, configured from the object catalog's
## `view` block (shape/color/height). Entries without a model render as
## colored primitives — the placeholder strategy (design_m3.md §7.1):
## every entry works as a primitive first, models land incrementally
## without code changes. Holds no game state beyond selection highlight;
## per-tick presentation (growth, capsule altitude, damage) is driven by
## sync_state() reading the sim entity.

enum Kind { UNIT, RESOURCE }

const FACTION_PLAYER := 0
const FACTION_ENEMY := 1
const FACTION_NEUTRAL := 2

const COLORS := {
	FACTION_PLAYER: Color(0.26, 0.65, 0.96),
	FACTION_ENEMY: Color(0.9, 0.22, 0.21),
	FACTION_NEUTRAL: Color(0.99, 0.85, 0.21),
}

## Capsules hover this high until they land (view-side flavor only).
const CAPSULE_ALTITUDE := 5.0

var kind := Kind.UNIT
var faction := FACTION_NEUTRAL
## Sim entity this node visualizes.
var entity_id := 0
## Catalog type of the entity, for "select all of this type" gestures.
var type_key := 0
## Only own units enter the selection; everything is a valid order target.
var selectable := false
var selected := false:
	set(value):
		selected = value
		if _ring != null:
			_ring.visible = value

var _body: MeshInstance3D
var _mat: StandardMaterial3D
var _base_color := Color.WHITE
var _base_height := 1.0
var _ring: MeshInstance3D
var _bar_back: MeshInstance3D
var _bar_front: MeshInstance3D
var _bob := 0.0
## Resource node amount at view creation, for the depletion tint.
var _initial_amount := 0


## Catalog-driven construction. `view_block` comes from the compiled
## catalog (free-form; absent keys fall back to faction primitives).
static func from_entity(e: SimEntity, view_block: Dictionary,
		p_faction: int, pos: Vector3) -> UnitView:
	var u := UnitView.new()
	u.kind = Kind.UNIT if e.is_unit() else Kind.RESOURCE
	u.faction = p_faction
	u.entity_id = e.id
	u.type_key = e.type_key
	u.position = pos
	u.selectable = e.is_unit() and p_faction == FACTION_PLAYER
	u._initial_amount = e.amount
	u._build_body(e, view_block)
	return u


func _build_body(e: SimEntity, view: Dictionary) -> void:
	_base_color = Color(view["color"]) if view.has("color") else COLORS[faction]
	_mat = StandardMaterial3D.new()
	_mat.albedo_color = _base_color
	_body = MeshInstance3D.new()
	var shape: String = view.get("shape", "capsule" if e.is_unit() else "box")
	var height: float = view.get("height", 1.6 if e.is_unit() else 1.2)
	_base_height = height
	match shape:
		"capsule":
			var capsule := CapsuleMesh.new()
			capsule.radius = maxf(0.2, Fixed.to_float(e.radius))
			capsule.height = height
			capsule.material = _mat
			_body.mesh = capsule
		"cylinder":
			var cyl := CylinderMesh.new()
			cyl.top_radius = e.foot_w * 0.5 / SimGrid.PATH_SUBDIV * 0.9
			cyl.bottom_radius = cyl.top_radius
			cyl.height = height
			cyl.material = _mat
			_body.mesh = cyl
		_:
			var box := BoxMesh.new()
			if e.is_unit():
				box.size = Vector3(0.8, height, 0.8)
			else:
				box.size = Vector3(float(e.foot_w) / SimGrid.PATH_SUBDIV * 0.95,
						height, float(e.foot_h) / SimGrid.PATH_SUBDIV * 0.95)
			box.material = _mat
			_body.mesh = box
	_body.position.y = height / 2.0
	add_child(_body)


func _ready() -> void:
	add_to_group("units")
	if selectable:
		_ring = MeshInstance3D.new()
		var ring_mesh := TorusMesh.new()
		ring_mesh.inner_radius = 0.8
		ring_mesh.outer_radius = 1.0
		var ring_mat := StandardMaterial3D.new()
		ring_mat.albedo_color = Color(0.4, 0.95, 0.55)
		ring_mat.emission_enabled = true
		ring_mat.emission = Color(0.3, 0.9, 0.45)
		ring_mesh.material = ring_mat
		_ring.mesh = ring_mesh
		_ring.scale = Vector3(1.0, 0.25, 1.0)
		_ring.position.y = 0.08
		_ring.visible = selected
		add_child(_ring)


## Per-tick presentation from sim state. The capsule "flies" by altitude
## (descending as its timer runs out); growth scales the body; damage
## shows a billboard bar (damaged entities only — thumbnail readability).
func sync_state(e: SimEntity, capsule_time_ticks: int) -> void:
	if e.is_unit():
		visible = visible and not e.is_underground()
		_body.scale.y = 1.3 if e.morphed else 1.0
		_update_health_bar(e)
		return
	if e.kind != SimEntity.Kind.STRUCTURE:
		# Resource node depletion tint (§7.3).
		if _initial_amount > 0 and _mat != null:
			var left := clampf(float(e.amount) / _initial_amount, 0.0, 1.0)
			_mat.albedo_color = _base_color.darkened(0.75 * (1.0 - left))
		return
	match e.build_state:
		SimEntity.BuildState.CAPSULE:
			var t := 1.0
			if capsule_time_ticks > 0:
				t = clampf(float(e.build_ticks_left) / Fixed.from_int(capsule_time_ticks), 0.0, 1.0)
			_bob += 0.12
			_body.position.y = _base_height / 2.0 \
					+ CAPSULE_ALTITUDE * (0.3 + 0.7 * t) + sin(_bob) * 0.2
			_body.scale = Vector3(0.5, 0.5, 0.5)
			_mat.albedo_color = _base_color.lightened(0.3)
		SimEntity.BuildState.GROWING:
			var total := 1.0
			var s := 1.0
			if e.max_hp > 0:
				total = float(e.hp) / e.max_hp # hp ramps with progress (§4.5)
				s = 0.3 + 0.7 * clampf(total, 0.1, 1.0)
			_body.position.y = _base_height * s / 2.0
			_body.scale = Vector3(s, s, s)
			_mat.albedo_color = _base_color.darkened(0.35)
		_:
			_body.position.y = _base_height / 2.0
			_body.scale = Vector3.ONE
			_mat.albedo_color = _base_color
	_update_health_bar(e)


func _update_health_bar(e: SimEntity) -> void:
	var damaged := e.hp < e.max_hp and e.hp > 0 \
			and e.build_state == SimEntity.BuildState.COMPLETE
	if not damaged:
		if _bar_back != null:
			_bar_back.visible = false
			_bar_front.visible = false
		return
	if _bar_back == null:
		_bar_back = _make_bar(Color(0.1, 0.1, 0.1, 0.8), 0.0)
		_bar_front = _make_bar(Color(0.3, 0.9, 0.35, 0.95), 0.01)
	_bar_back.visible = true
	_bar_front.visible = true
	var frac := float(e.hp) / e.max_hp
	_bar_front.scale.x = maxf(0.02, frac)
	_bar_front.position.x = -(1.0 - frac) * 0.6
	var tint := Color(0.3, 0.9, 0.35) if frac > 0.5 \
			else (Color(0.95, 0.8, 0.2) if frac > 0.25 else Color(0.9, 0.25, 0.2))
	(_bar_front.mesh as QuadMesh).material.albedo_color = tint


func _make_bar(color: Color, z_off: float) -> MeshInstance3D:
	var bar := MeshInstance3D.new()
	var quad := QuadMesh.new()
	quad.size = Vector2(1.2, 0.14)
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	quad.material = mat
	bar.mesh = quad
	bar.position = Vector3(0.0, _base_height + 0.6, z_off)
	add_child(bar)
	return bar
