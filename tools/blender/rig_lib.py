"""Shared Blender helpers for the unit pipeline: rig construction and posing.

Imported by rig_unit.py and by every per-unit animation module (anim_*.py).
Nothing here knows about a specific creature — the body plan comes from a
`units.Unit` spec. What *is* shared, because it is the same maths for every
unit we build:

  * OBJ import, orientation, height normalisation, feet-on-z=0 origin (or a
    flyer's `hover` clearance above it);
  * bone-chain construction, including the mirrored insect leg (upper / lower
    / foot with a bowed ankle) and pairs that hang off other pairs ("{s}");
  * skinning with the glTF 4-influence cap, including a nearest-bone fallback
    for islands bone heat cannot reach (`bind_orphans`);
  * pose maths (`set_rot` / `set_loc`), action creation on Blender 5.x slotted
    actions, keyframe interpolation control, NLA stashing;
  * the hexapod tripod gait;
  * `min_z_per_frame`, the ground-clipping measurement — a deformed mesh that
    dips below z=0 reads as clipping through the terrain.

Sign conventions (the creature faces -Y, Z is up):
  * world (1,0,0) pitches: +deg pitches the head DOWN (a strike), -deg rears up
  * world (0,0,1) yaws a leg fore/aft; world (0,1,0) lifts it (negative * side
    sign raises)
"""

import bpy
import math
import mathutils

FPS = 24


# --- scene bootstrap ---------------------------------------------------------

def reset_scene():
    bpy.ops.wm.read_homefile(use_empty=True)
    sc = bpy.context.scene
    sc.unit_settings.system = 'METRIC'
    sc.frame_start = 1
    return sc


def import_body(spec):
    """Import the spec's OBJ, orient it head--Y / Z-up, normalise, drop to z=0.

    A spec may declare an optional `hover` clearance (metres). Ground units
    leave it at 0 and land with their feet exactly on z=0, as before; a FLYER
    sets it and the whole mesh is lifted by that much while the origin stays
    at ground level, so Godot places the model on the terrain and it visually
    floats. The sim has no notion of flight (see units.LASER_MOTH) -- this is
    the entire mechanism, and it costs the sim and the view layer nothing.
    """
    bpy.ops.wm.obj_import(filepath=spec.obj_path)
    ob = [o for o in bpy.context.scene.objects if o.type == 'MESH'][0]
    ob.name = spec.mesh_name
    ob.data.name = spec.mesh_name
    bpy.context.view_layer.objects.active = ob
    for o in bpy.context.scene.objects:
        o.select_set(o is ob)

    for rot in spec.import_rotations:
        ob.rotation_euler = tuple(math.radians(a) for a in rot)
        bpy.ops.object.transform_apply(location=False, rotation=True, scale=False)

    co = [vt.co for vt in ob.data.vertices]
    height = max(c.z for c in co) - min(c.z for c in co)
    s = spec.target_height / height
    ob.scale = (s, s, s)
    bpy.ops.object.transform_apply(location=False, rotation=False, scale=True)

    # Feet exactly on z=0 and centred on X/Y: that is the transform Godot
    # places on the ground. A flyer's `hover` raises the mesh off that floor
    # while leaving the origin on it.
    hover = float(getattr(spec, "hover", 0.0))
    co = [vt.co for vt in ob.data.vertices]
    zmin = min(c.z for c in co)
    xmid = (max(c.x for c in co) + min(c.x for c in co)) / 2
    ymid = (max(c.y for c in co) + min(c.y for c in co)) / 2
    for vt in ob.data.vertices:
        vt.co.x -= xmid
        vt.co.y -= ymid
        vt.co.z -= zmin - hover

    # Tripo exports carry degenerate/duplicate geometry that makes the glTF
    # exporter warn "mesh is not valid"; validate() repairs it in place.
    if ob.data.validate(verbose=False):
        print("note: repaired invalid geometry in the source mesh")

    bpy.ops.object.shade_smooth()
    if hasattr(ob.data, "use_auto_smooth"):
        ob.data.use_auto_smooth = True
    return ob


# --- armature ----------------------------------------------------------------

def _v(t):
    return mathutils.Vector(t)


def build_armature(spec):
    """Build root + spine + mirrored pairs + legs from the spec's body plan."""
    arm_data = bpy.data.armatures.new(spec.arm_name)
    arm = bpy.data.objects.new(spec.arm_name, arm_data)
    bpy.context.scene.collection.objects.link(arm)
    bpy.context.view_layer.objects.active = arm
    for o in bpy.context.scene.objects:
        o.select_set(o is arm)
    bpy.ops.object.mode_set(mode='EDIT')
    eb = arm_data.edit_bones
    made = {}

    def bone(name, head, tail, parent="", connect=False):
        b = eb.new(name)
        b.head = _v(head)
        b.tail = _v(tail)
        if parent:
            b.parent = made[parent]
            b.use_connect = connect
        made[name] = b
        return b

    bone(spec.root.name, spec.root.head, spec.root.tail)
    for sb in spec.spine:
        bone(sb.name, sb.head, sb.tail, sb.parent, sb.connect)

    for pair in spec.pairs:
        for s, tag in ((-1.0, "L"), (1.0, "R")):
            # "{s}" in a parent name is the side tag, so one mirrored pair can
            # hang off ANOTHER mirrored pair -- a two-segment wing, where
            # L_wing_tip must follow L_wing and not R_wing. Names without it
            # are used verbatim, which is every pre-existing spec.
            bone(f"{tag}_{pair.name}",
                 (s * pair.head[0], pair.head[1], pair.head[2]),
                 (s * pair.tail[0], pair.tail[1], pair.tail[2]),
                 pair.parent.replace("{s}", tag))

    for leg in spec.legs:
        for s, tag in ((-1.0, "L"), (1.0, "R")):
            hp = _v((s * leg.hip[0], leg.hip[1], leg.hip[2]))
            kn = _v((s * leg.knee[0], leg.knee[1], leg.knee[2]))
            ft = _v((s * leg.foot[0], leg.foot[1], leg.foot[2]))
            ankle = kn.lerp(ft, leg.ankle_t)
            ankle.x += s * leg.ankle_bow
            base = f"{tag}_{leg.name}"
            bone(f"{base}_upper", hp, kn, leg.parent)
            bone(f"{base}_lower", kn, ankle, f"{base}_upper", connect=True)
            bone(f"{base}_foot", ankle, ft, f"{base}_lower", connect=True)

    bpy.ops.object.mode_set(mode='OBJECT')
    return arm


def _point_segment_distance(p, a, b):
    ab = b - a
    denom = ab.dot(ab)
    t = 0.0 if denom <= 0.0 else max(0.0, min(1.0, (p - a).dot(ab) / denom))
    return (p - (a + ab * t)).length


def bind_orphans(body, arm, skip=()):
    """Weight any vertex bone heat left unbound to its nearest bone.

    Bone heat solves on the mesh's own connectivity, so a small ISLAND that
    encloses no bone gets no weight at all and then sits dead still while the
    rest of the creature moves. That never came up on the first three units --
    each is a single well-formed shell -- but the carapace is a 63-shell
    kit-bash whose side pods and leg spikes are separate closed volumes, and
    169 of its 1059 vertices came back unbound.

    Nearest-bone-segment, full weight, which is right for a rigid greeble
    bolted to one part. Returns the number of vertices fixed, so a rig that
    never had the problem reports 0 and is completely unaffected.
    """
    segments = []
    for bone in arm.data.bones:
        if bone.name in skip:
            continue
        segments.append((bone.name,
                         arm.matrix_world @ bone.head_local,
                         arm.matrix_world @ bone.tail_local))
    if not segments:
        return 0
    fixed = 0
    for v in body.data.vertices:
        if v.groups:
            continue
        p = body.matrix_world @ v.co
        name = min(segments, key=lambda s: _point_segment_distance(p, s[1], s[2]))[0]
        group = body.vertex_groups.get(name) or body.vertex_groups.new(name=name)
        group.add([v.index], 1.0, 'REPLACE')
        fixed += 1
    return fixed


def skin(body, arm, root_bone="root"):
    """Bind with bone-heat weights, falling back to envelopes if heat fails."""
    bpy.ops.object.mode_set(mode='OBJECT')
    for o in bpy.context.scene.objects:
        o.select_set(False)
    body.select_set(True)
    arm.select_set(True)
    bpy.context.view_layer.objects.active = arm
    try:
        bpy.ops.object.parent_set(type='ARMATURE_AUTO')
        mode = "heat"
    except RuntimeError:
        bpy.ops.object.parent_set(type='ARMATURE_ENVELOPE')
        mode = "envelope"
    # The placement bone must not steal weight from the body.
    vg = body.vertex_groups.get(root_bone)
    if vg is not None:
        body.vertex_groups.remove(vg)

    # Islands bone heat could not reach would otherwise never deform.
    orphans = bind_orphans(body, arm, skip=(root_bone,))
    if orphans:
        mode = f"{mode}+{orphans} nearest-bone"

    # glTF keeps only the 4 heaviest influences per vertex. Cap them here so
    # what Blender previews is what Godot actually plays.
    bpy.context.view_layer.objects.active = body
    for o in bpy.context.scene.objects:
        o.select_set(o is body)
    bpy.ops.object.vertex_group_limit_total(limit=4)
    bpy.ops.object.vertex_group_normalize_all(lock_active=False)

    bpy.context.view_layer.objects.active = arm
    return mode


# --- pose maths --------------------------------------------------------------

def sign(tag):
    """Mirror sign for a side tag; L is -X."""
    return -1.0 if tag == "L" else 1.0


def set_rot(pb, *world_rots):
    """Set a pose bone's rotation from world-space axis/angle (degrees) pairs.

    Always rebuilt from the rest pose rather than composed onto the current
    value, so repeated keyframing cannot drift.
    """
    m = pb.bone.matrix_local.to_3x3()
    minv = m.inverted()
    q = mathutils.Quaternion((1, 0, 0, 0))
    for axis, deg in world_rots:
        if not deg:
            continue
        la = (minv @ mathutils.Vector(axis)).normalized()
        q = q @ mathutils.Quaternion(la, math.radians(deg))
    pb.rotation_mode = 'QUATERNION'
    pb.rotation_quaternion = q


def set_loc(pb, world_vec):
    """Set a pose bone's location from a world-space offset.

    `pose_bone.location` is expressed in the bone's own space, which for a
    spine bone lying along -Y is nothing like world XYZ -- so translations are
    written in world terms and converted here.
    """
    m = pb.bone.matrix_local.to_3x3()
    pb.location = m.inverted() @ mathutils.Vector(world_vec)


def rest(arm):
    for pb in arm.pose.bones:
        pb.rotation_mode = 'QUATERNION'
        pb.rotation_quaternion = (1, 0, 0, 0)
        pb.location = (0, 0, 0)
        pb.scale = (1, 1, 1)


def key(arm, frame, bones, loc_bones=(), scale_bones=()):
    """Key rotation on `bones`, plus translation / scale where asked.

    Scale is a real animation channel in glTF, so a bone with no children --
    a venom sac, a throat -- can swell and deflate as part of a clip.
    """
    for name in bones:
        arm.pose.bones[name].keyframe_insert("rotation_quaternion", frame=frame)
    for name in loc_bones:
        arm.pose.bones[name].keyframe_insert("location", frame=frame)
    for name in scale_bones:
        arm.pose.bones[name].keyframe_insert("scale", frame=frame)


def new_action(arm, name):
    old = bpy.data.actions.get(name)
    if old is not None:
        bpy.data.actions.remove(old)
    act = bpy.data.actions.new(name)
    act.use_fake_user = True
    if arm.animation_data is None:
        arm.animation_data_create()
    arm.animation_data.action = act
    # Blender 4.4+ slotted actions: bind the slot so keys land on this rig.
    slot = getattr(arm.animation_data, "action_slot", None)
    if slot is None and hasattr(act, "slots"):
        try:
            arm.animation_data.action_slot = act.slots.new(id_type='OBJECT', name=name)
        except (AttributeError, TypeError, RuntimeError):
            pass
    return act


def bind_action(arm, act):
    """Make an existing action current, slot and all (for previews/checks)."""
    if arm.animation_data is None:
        arm.animation_data_create()
    arm.animation_data.action = act
    slots = getattr(act, "slots", None)
    if slots:
        try:
            arm.animation_data.action_slot = slots[0]
        except (AttributeError, TypeError, RuntimeError):
            pass


def set_range(act, first, last, cyclic=True):
    act.use_frame_range = True
    act.frame_start, act.frame_end = first, last
    act.use_cyclic = cyclic


def action_fcurves(act):
    """F-curves of an action, across the pre/post 4.4 layout change.

    Blender 4.4 moved keyframes out of `Action.fcurves` and into
    layer -> strip -> channelbag, so reach through whichever exists.
    """
    if hasattr(act, "fcurves"):
        return list(act.fcurves)
    out = []
    for layer in act.layers:
        for strip in layer.strips:
            for cb in strip.channelbags:
                out.extend(cb.fcurves)
    return out


def smooth_action(act):
    """Default everything to eased bezier -- right for cycles, mush for snaps."""
    for fc in action_fcurves(act):
        for kp in fc.keyframe_points:
            kp.interpolation = 'BEZIER'
            kp.handle_left_type = kp.handle_right_type = 'AUTO_CLAMPED'


def set_frame_interp(act, frame, interpolation, easing='AUTO'):
    """Override the interpolation *leaving* the keys on one frame.

    This is how a fast action stays fast: AUTO_CLAMPED bezier eases out of
    every key, which turns a 2-frame strike into a slow drift. 'LINEAR' on the
    key the strike leaves from makes it travel at full speed immediately;
    'CONSTANT' holds a pose dead still until the next key.
    """
    for fc in action_fcurves(act):
        for kp in fc.keyframe_points:
            if abs(kp.co[0] - frame) < 1e-4:
                kp.interpolation = interpolation
                if interpolation not in ('CONSTANT', 'LINEAR', 'BEZIER'):
                    kp.easing = easing


def ease_out_of(act, frame):
    """Vector handles on one key: no ease-in, no ease-out through it."""
    for fc in action_fcurves(act):
        for kp in fc.keyframe_points:
            if abs(kp.co[0] - frame) < 1e-4:
                kp.handle_left_type = kp.handle_right_type = 'VECTOR'


# --- hexapod gait ------------------------------------------------------------

def tripods(leg_names):
    """Split an insect's legs into the two alternating tripod groups.

    Legs alternate sides down the body: (L, front), (R, mid), (L, rear) swing
    together while the other three take the weight.
    """
    a, b = [], []
    for i, leg in enumerate(leg_names):
        first, second = ("L", "R") if i % 2 == 0 else ("R", "L")
        a.append((first, leg))
        b.append((second, leg))
    return tuple(a), tuple(b)


def all_legs(leg_names):
    return [(t, l) for t in ("L", "R") for l in leg_names]


def leg_gait(arm, tag, leg, phase, reach=20.0, lift=30.0, curl=22.0):
    """One leg at a point in the gait cycle.

    phase 0.0-0.5 is swing (lifted, travelling forward), 0.5-1.0 is stance
    (planted, driving backward).
    """
    s = sign(tag)
    p = phase % 1.0
    if p < 0.5:                       # swing: lift and reach forward
        k = p / 0.5
        up = math.sin(k * math.pi) * lift
        # -Y is forward, so a positive world-Z yaw on the right side reaches ahead.
        swing = (-1.0 + 2.0 * k) * reach
        fold = math.sin(k * math.pi) * curl
    else:                             # stance: planted, pushing back
        k = (p - 0.5) / 0.5
        up = 0.0
        swing = (1.0 - 2.0 * k) * reach
        fold = 0.0
    # Negative world-Y rotation raises a leg, so lift and curl share that sign:
    # the femur lifts, the tibia folds up under it, and the tip drops a little.
    set_rot(arm.pose.bones[f"{tag}_{leg}_upper"],
            ((0, 0, 1), swing * s), ((0, 1, 0), -up * s))
    set_rot(arm.pose.bones[f"{tag}_{leg}_lower"], ((0, 1, 0), -fold * s))
    set_rot(arm.pose.bones[f"{tag}_{leg}_foot"], ((0, 1, 0), fold * 0.4 * s))


# --- assembly ----------------------------------------------------------------

def stash_to_nla(arm, actions):
    """One muted NLA track per action.

    The glTF exporter walks NLA tracks to emit named clips; muting them keeps
    the viewport on the rest pose so the .blend opens in a sane state.
    """
    ad = arm.animation_data
    for tr in list(ad.nla_tracks):
        ad.nla_tracks.remove(tr)
    ad.action = None
    for act in actions:
        track = ad.nla_tracks.new()
        track.name = act.name
        strip = track.strips.new(act.name, int(act.frame_start), act)
        strip.name = act.name
        track.mute = True


def finalize(arm, actions, scene_end=48):
    """Stash the built actions and leave the file in a sane opening state."""
    stash_to_nla(arm, actions)
    rest(arm)
    bpy.ops.object.mode_set(mode='OBJECT')
    bpy.context.scene.render.fps = FPS
    bpy.context.scene.frame_start = 0
    bpy.context.scene.frame_end = scene_end
    return actions


def enter_pose_mode(arm):
    bpy.context.view_layer.objects.active = arm
    for o in bpy.context.scene.objects:
        o.select_set(o is arm)
    bpy.ops.object.mode_set(mode='POSE')


# --- verification ------------------------------------------------------------

def min_z_per_frame(arm, mesh, act):
    """Lowest deformed-vertex Z on every frame of an action.

    Anything below ~0 is the mesh sinking through the terrain. Rising is fine
    (and wanted, during a lunge) -- only sinking is a defect.
    """
    scene = bpy.context.scene
    prev_action = arm.animation_data.action if arm.animation_data else None
    bind_action(arm, act)
    dg = bpy.context.evaluated_depsgraph_get()
    out = []
    for f in range(int(act.frame_start), int(act.frame_end) + 1):
        scene.frame_set(f)
        dg.update()
        ev = mesh.evaluated_get(dg)
        me = ev.to_mesh()
        mw = ev.matrix_world
        out.append((f, min((mw @ v.co).z for v in me.vertices)))
        ev.to_mesh_clear()
    if prev_action is not None:
        bind_action(arm, prev_action)
    return out
