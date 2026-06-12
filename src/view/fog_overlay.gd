class_name FogOverlay
extends MeshInstance3D
## Fog-of-war ground presentation (design_m3.md §7.3): one map-sized quad
## just above the ground whose shader dims tiles outside the local
## player's vision. The texture is the sim's per-player visibility bitmap,
## refreshed at the fog cadence. Entities under fog are hidden by the
## entity views, not by this overlay.

const REFRESH := 0.25

var sim: Sim
var local_player := 1
var world_offset := 32.0

var _texture: ImageTexture
var _accum := 999.0


func _ready() -> void:
	var plane := PlaneMesh.new()
	plane.size = Vector2(sim.grid.tiles_w, sim.grid.tiles_h)
	mesh = plane
	position = Vector3(0.0, 0.06, 0.0)

	var shader := Shader.new()
	shader.code = """
shader_type spatial;
render_mode unshaded, blend_mix, shadows_disabled;
uniform sampler2D fog_tex : filter_nearest;
void fragment() {
	float visible_v = texture(fog_tex, UV).r;
	ALBEDO = vec3(0.02, 0.02, 0.03);
	ALPHA = visible_v > 0.002 ? 0.0 : 0.55;
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
	var img := Image.create_from_data(sim.grid.tiles_w, sim.grid.tiles_h,
			false, Image.FORMAT_R8, vis)
	if _texture == null:
		_texture = ImageTexture.create_from_image(img)
		(material_override as ShaderMaterial).set_shader_parameter("fog_tex", _texture)
	else:
		_texture.update(img)
