class_name UnitView
extends Node3D
## Visualization of one sim entity: a colored capsule (or box for
## resources). Holds no game state beyond selection highlight — position
## comes from the sim each tick (interpolated by Main); orders go the
## other way exclusively as SimCommands.

enum Kind { UNIT, RESOURCE }

const FACTION_PLAYER := 0
const FACTION_ENEMY := 1
const FACTION_NEUTRAL := 2

const COLORS := {
	FACTION_PLAYER: Color(0.26, 0.65, 0.96),
	FACTION_ENEMY: Color(0.9, 0.22, 0.21),
	FACTION_NEUTRAL: Color(0.99, 0.85, 0.21),
}

var kind := Kind.UNIT
var faction := FACTION_NEUTRAL
## Sim entity this node visualizes; 0 = view-only (resources until M3).
var entity_id := 0
var selected := false:
	set(value):
		selected = value
		if _ring != null:
			_ring.visible = value

var _ring: MeshInstance3D


static func make(p_kind: Kind, p_faction: int, pos: Vector3) -> UnitView:
	var u := UnitView.new()
	u.kind = p_kind
	u.faction = p_faction
	u.position = pos
	return u


func _ready() -> void:
	add_to_group("units")
	var body := MeshInstance3D.new()
	var mat := StandardMaterial3D.new()
	mat.albedo_color = COLORS[faction]
	if kind == Kind.RESOURCE:
		var box := BoxMesh.new()
		box.size = Vector3(1.6, 1.2, 1.6)
		box.material = mat
		body.mesh = box
		body.position.y = 0.6
	else:
		var capsule := CapsuleMesh.new()
		capsule.radius = 0.45
		capsule.height = 1.7
		capsule.material = mat
		body.mesh = capsule
		body.position.y = 0.85
	add_child(body)

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
