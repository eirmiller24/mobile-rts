class_name FogOverlay
extends MeshInstance3D
## Fog-of-war ground presentation. M4 (design_m4.md §6.1) makes this
## three-state: unexplored (never seen, solid black), explored (seen before,
## not now — dimmed, terrain known), visible (bright). "explored" is a
## cumulative OR of the sim's per-tick visibility bitmaps and lives entirely
## in the view (no sim rule reads it — the seam M3 §4.4 left). The texture's
## R channel is current visibility, G is the accumulated explored mask.

const REFRESH := 0.25

var sim: Sim
var local_player := 1
var world_offset := 32.0

var _texture: ImageTexture
var _explored := PackedByteArray()
var _rg := PackedByteArray()
var _accum := 999.0


func _ready() -> void:
	var plane := PlaneMesh.new()
	plane.size = Vector2(sim.grid.tiles_w, sim.grid.tiles_h)
	mesh = plane
	position = Vector3(0.0, 0.06, 0.0)
	_explored.resize(sim.grid.tiles_w * sim.grid.tiles_h)
	_rg.resize(sim.grid.tiles_w * sim.grid.tiles_h * 2)

	var shader := Shader.new()
	shader.code = """
shader_type spatial;
render_mode unshaded, blend_mix, shadows_disabled;
uniform sampler2D fog_tex : filter_nearest;
void fragment() {
	vec2 f = texture(fog_tex, UV).rg;  // r = visible now, g = ever explored
	ALBEDO = vec3(0.02, 0.02, 0.03);
	// visible -> clear; explored -> dim; unexplored -> black.
	ALPHA = f.r > 0.002 ? 0.0 : (f.g > 0.002 ? 0.4 : 0.78);
}
"""
	var mat := ShaderMaterial.new()
	mat.shader = shader
	material_override = mat


func _process(delta: float) -> void:
	_accum += delta
	if _accum < REFRESH:
		return
	_accum = 0.0
	var vis := sim.vision_of(local_player)
	if vis.is_empty():
		return
	for i in vis.size():
		var v: int = vis[i]
		if v != 0:
			_explored[i] = 1
		_rg[i * 2] = 255 if v != 0 else 0
		_rg[i * 2 + 1] = 255 if _explored[i] != 0 else 0
	var img := Image.create_from_data(sim.grid.tiles_w, sim.grid.tiles_h,
			false, Image.FORMAT_RG8, _rg)
	if _texture == null:
		_texture = ImageTexture.create_from_image(img)
		(material_override as ShaderMaterial).set_shader_parameter("fog_tex", _texture)
	else:
		_texture.update(img)
