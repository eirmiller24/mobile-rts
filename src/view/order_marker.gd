class_name OrderMarker
extends Node3D
## Short-lived ground marker confirming an order, tinted by the command's
## catalog color so the player gets feedback without watching the units.

const LIFETIME := 0.8

var color := Color.WHITE

var _age := 0.0
var _disc: MeshInstance3D
var _mat: StandardMaterial3D


static func spawn(parent: Node, world_pos: Vector3, p_color: Color) -> void:
	var marker := OrderMarker.new()
	marker.color = p_color
	marker.position = world_pos
	parent.add_child(marker)


func _ready() -> void:
	_disc = MeshInstance3D.new()
	var mesh := CylinderMesh.new()
	mesh.top_radius = 0.7
	mesh.bottom_radius = 0.7
	mesh.height = 0.05
	_mat = StandardMaterial3D.new()
	_mat.albedo_color = color
	_mat.emission_enabled = true
	_mat.emission = color
	_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mesh.material = _mat
	_disc.mesh = mesh
	_disc.position.y = 0.05
	add_child(_disc)


func _process(delta: float) -> void:
	_age += delta
	if _age >= LIFETIME:
		queue_free()
		return
	var t := _age / LIFETIME
	_disc.scale = Vector3.ONE * (1.0 + t * 0.8)
	_mat.albedo_color.a = 1.0 - t
