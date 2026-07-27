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

## How fast a unit turns toward where it is going, in radians/second. Facing is
## pure presentation — the sim has no heading — so it is derived here from the
## movement the sim already produced.
const TURN_SPEED := 9.0
## Sim-units of movement per tick below which a unit counts as standing still.
const MOVE_EPSILON := 0.004

## Animation state keys; the catalog's `view.animations` block maps these to
## clip names inside the model, so a model with different clip names needs no
## code change (design.md "UI as Data" applies to view data too).
const ANIM_IDLE := "idle"
const ANIM_MOVE := "move"
const ANIM_ATTACK := "attack"

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

## The node the presentation transforms (growth, capsule altitude, morph) act
## on: the primitive mesh, or the model root when the catalog supplies one.
var _visual: Node3D
## Uniform scale the model was authored at; presentation scaling multiplies it.
var _visual_scale := 1.0
## Resting height of the visual's origin. Primitive meshes are centred so they
## sit at half their height; models are authored origin-at-feet, so they sit at
## zero and grow upward from the ground.
var _visual_y := 0.0
var _anim: AnimationPlayer
## Animation state key -> clip name in the model, from the catalog.
var _clips := {}
var _anim_state := ""
## Set while a one-shot (attack) clip is playing and must not be interrupted.
var _oneshot_until := 0.0
## Previous tick's sim position, for deriving movement and facing.
var _prev_sim := Vector2.ZERO
var _has_prev_sim := false
## Previous tick's attack cooldown; a rise means an attack fired this tick.
var _prev_cooldown := 0
var _target_yaw := 0.0
var _has_yaw := false


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
	_base_height = view.get("height", 1.6 if e.is_unit() else 1.2)
	if _build_model(view):
		return
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
	_visual_y = height / 2.0
	_body.position.y = _visual_y
	add_child(_body)
	_visual = _body


## Instance the catalog's `view.model` if it names one that loads. Returns
## false so _build_body falls back to primitives when there is no model (or it
## is missing) — that fallback is what lets models land one entry at a time.
func _build_model(view: Dictionary) -> bool:
	var path: String = str(view.get("model", ""))
	if path == "" or not ResourceLoader.exists(path):
		return false
	var packed := ResourceLoader.load(path) as PackedScene
	if packed == null:
		push_warning("UnitView: view.model is not a scene: %s" % path)
		return false
	var inst := packed.instantiate() as Node3D
	if inst == null:
		push_warning("UnitView: view.model root is not a Node3D: %s" % path)
		return false

	# Models are authored at final game scale facing -Z (Godot forward), so
	# these are corrections for assets that are not.
	var s: float = float(view.get("model_scale", 1.0))
	_visual_scale = s
	inst.scale = Vector3(s, s, s)
	var yaw: float = float(view.get("model_yaw", 0.0))
	if not is_zero_approx(yaw):
		inst.rotation.y = deg_to_rad(yaw)
	add_child(inst)
	_visual = inst

	_clips = view.get("animations", {})
	_anim = _find_anim_player(inst)
	if _anim != null:
		# glTF carries no loop flag, so the looping states are set here; the
		# one-shot attack clip is deliberately left un-looped.
		for state in [ANIM_IDLE, ANIM_MOVE]:
			var clip: String = str(_clips.get(state, ""))
			if _anim.has_animation(clip):
				_anim.get_animation(clip).loop_mode = Animation.LOOP_LINEAR
		_play_state(ANIM_IDLE)
	return true


## Yaw that aims the model's forward down a view-space direction (dx, dz).
## Models face -Z at yaw 0, and rotating -Z by yaw y gives (-sin y, -cos y),
## so the aim is atan2 of the *negated* direction — i.e. half a turn past it.
## Both facing sources go through here so they cannot drift apart.
static func _yaw_toward(dx: float, dz: float) -> float:
	return atan2(dx, dz) + PI


## Current animation state key (one of the ANIM_* constants), or "" when the
## entry has no model. Exposed for the headless view checks.
func anim_state() -> String:
	return _anim_state


## Yaw the unit is turning toward, in radians. Exposed for the headless checks.
func facing_yaw() -> float:
	return _target_yaw


## Presentation scaling, on top of whatever scale the model was authored at.
func _set_visual_scale(f: float) -> void:
	var s := _visual_scale * f
	_visual.scale = Vector3(s, s, s)


## Faction/state tinting. Only meaningful for primitives — a textured model
## carries its own materials and is left alone.
func _tint(color: Color) -> void:
	if _mat != null:
		_mat.albedo_color = color


func _find_anim_player(node: Node) -> AnimationPlayer:
	if node is AnimationPlayer:
		return node
	for child in node.get_children():
		var found := _find_anim_player(child)
		if found != null:
			return found
	return null


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


## Play the clip mapped to an animation state key, if the model has one.
## `oneshot` clips hold the state until they finish (see _process).
func _play_state(state: String, oneshot := false) -> void:
	if _anim == null or _anim_state == state:
		return
	var clip: String = str(_clips.get(state, ""))
	if not _anim.has_animation(clip):
		return
	_anim_state = state
	_anim.play(clip)
	_oneshot_until = _anim.get_animation(clip).length if oneshot else 0.0


## Facing and one-shot timing run per frame, not per tick, so turns stay smooth
## against the interpolated positions main.gd writes.
func _process(delta: float) -> void:
	if _oneshot_until > 0.0:
		_oneshot_until -= delta
		if _oneshot_until <= 0.0:
			_anim_state = ""   # release the hold; next sync_state re-picks
	if _has_yaw:
		rotation.y = rotate_toward(rotation.y, _target_yaw, TURN_SPEED * delta)


## Per-tick presentation from sim state. The capsule "flies" by altitude
## (descending as its timer runs out); growth scales the body; damage
## shows a billboard bar (damaged entities only — thumbnail readability).
## `target_pos` is the attack target's view position when the sim gave this
## entity one, so melee units face what they are biting.
func sync_state(e: SimEntity, capsule_time_ticks: int, target_pos = null) -> void:
	if e.is_unit():
		visible = visible and not e.is_underground()
		var morph := 1.3 if e.morphed else 1.0
		_visual.scale = Vector3(_visual_scale, _visual_scale * morph, _visual_scale)
		_sync_unit_motion(e, target_pos)
		_update_health_bar(e)
		return
	if e.kind != SimEntity.Kind.STRUCTURE:
		# Resource node depletion tint (§7.3).
		if _initial_amount > 0:
			var left := clampf(float(e.amount) / _initial_amount, 0.0, 1.0)
			_tint(_base_color.darkened(0.75 * (1.0 - left)))
		return
	match e.build_state:
		SimEntity.BuildState.CAPSULE:
			var t := 1.0
			if capsule_time_ticks > 0:
				t = clampf(float(e.build_ticks_left) / Fixed.from_int(capsule_time_ticks), 0.0, 1.0)
			_bob += 0.12
			_visual.position.y = _visual_y \
					+ CAPSULE_ALTITUDE * (0.3 + 0.7 * t) + sin(_bob) * 0.2
			_set_visual_scale(0.5)
			_tint(_base_color.lightened(0.3))
		SimEntity.BuildState.GROWING:
			var total := 1.0
			var s := 1.0
			if e.max_hp > 0:
				total = float(e.hp) / e.max_hp # hp ramps with progress (§4.5)
				s = 0.3 + 0.7 * clampf(total, 0.1, 1.0)
			_visual.position.y = _visual_y * s
			_set_visual_scale(s)
			_tint(_base_color.darkened(0.35))
		_:
			_visual.position.y = _visual_y
			_set_visual_scale(1.0)
			_tint(_base_color)
	_update_health_bar(e)


## Derive facing and animation state from the sim state the entity already
## carries. Nothing here writes to the sim: movement comes from comparing
## successive sim positions, and an attack is a *rise* in the cooldown counter
## (sim.gd sets cooldown = cooldown_ticks on the tick a shot lands).
func _sync_unit_motion(e: SimEntity, target_pos) -> void:
	var here := Vector2(Fixed.to_float(e.x), Fixed.to_float(e.y))
	var moved := Vector2.ZERO
	if _has_prev_sim:
		moved = here - _prev_sim
	_prev_sim = here
	_has_prev_sim = true

	var attacked := e.cooldown > _prev_cooldown
	_prev_cooldown = e.cooldown
	var is_moving := moved.length() > MOVE_EPSILON

	# Face the thing being attacked if the sim gave us one, else where we are
	# heading. Standing still with no target keeps the last facing.
	if target_pos != null:
		var to_target := (target_pos as Vector3) - position
		if Vector2(to_target.x, to_target.z).length_squared() > 0.0001:
			_target_yaw = _yaw_toward(to_target.x, to_target.z)
			_has_yaw = true
	elif is_moving:
		# Sim +y maps to view +z (main.gd _sim_to_view), so sim motion is a
		# view-space direction directly.
		_target_yaw = _yaw_toward(moved.x, moved.y)
		_has_yaw = true

	if _anim == null:
		return
	if attacked:
		_anim_state = ""            # restart even if already attacking
		_play_state(ANIM_ATTACK, true)
	elif _oneshot_until <= 0.0:
		_play_state(ANIM_MOVE if is_moving else ANIM_IDLE)


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
