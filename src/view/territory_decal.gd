class_name TerritoryDecal
extends Node3D
## Faction-tinted ground discs under every territory aura circle
## (design_m3.md §7.3), driven by the sim's aura-source batch read —
## they appear/disappear as strongholds and relays complete or die,
## with no wiring (the read just answers differently).

const REFRESH := 0.3

var sim: GameSim
var local_player := 1
var world_offset := 32.0
var tint := Color(0.25, 0.75, 0.35, 0.13)

var _sig := ""
var _accum := 999.0


func _process(delta: float) -> void:
	_accum += delta
	if _accum < REFRESH:
		return
	_accum = 0.0
	var circles: Array = sim.flagged_aura_circles(local_player, "territory")
	var sig := str(circles)
	if sig == _sig:
		return
	_sig = sig
	for child in get_children():
		child.queue_free()
	for c: Array in circles:
		var disc := MeshInstance3D.new()
		var cyl := CylinderMesh.new()
		cyl.top_radius = Fixed.to_float(c[2])
		cyl.bottom_radius = cyl.top_radius
		cyl.height = 0.02
		var mat := StandardMaterial3D.new()
		mat.albedo_color = tint
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		cyl.material = mat
		disc.mesh = cyl
		disc.position = Vector3(Fixed.to_float(c[0]) - world_offset, 0.03,
				Fixed.to_float(c[1]) - world_offset)
		add_child(disc)
