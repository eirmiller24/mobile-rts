"""Idle / Run / Attack actions for the Hive Mite rig.

Imported by rig_swarmer.py; safe to re-run on an existing rig (each build_*
call replaces its action). Poses are written as world-axis rotations per bone
and baked to quaternions, so the maths reads the way the motion looks:
`(0, 0, 1)` yaws a leg fore/aft, `(0, 1, 0)` lifts it, `(1, 0, 0)` pitches the
spine.

Animation direction (design.md "Art & Audio Direction"): the budget is small
and units are read at thumbnail size, so these favour few, high-contrast poses
over smooth realism -- the Hive "skitters and pulses".
"""

import bpy
import math
import mathutils

FPS = 24

# Insect tripod gait: these three legs swing together, the other three are
# half a cycle out of phase.
TRIPOD_A = (("L", "front"), ("R", "mid"), ("L", "rear"))
TRIPOD_B = (("R", "front"), ("L", "mid"), ("R", "rear"))
ALL_LEGS = [(t, l) for t in ("L", "R") for l in ("front", "mid", "rear")]


def _sign(tag):
    return -1.0 if tag == "L" else 1.0


def set_rot(pb, *world_rots):
    """Set a pose bone's rotation from world-space axis/angle pairs.

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


def key(arm, frame, bones, loc_bones=()):
    for name in bones:
        arm.pose.bones[name].keyframe_insert("rotation_quaternion", frame=frame)
    for name in loc_bones:
        arm.pose.bones[name].keyframe_insert("location", frame=frame)


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


def set_range(act, first, last):
    act.use_frame_range = True
    act.frame_start, act.frame_end = first, last
    act.use_cyclic = True


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


SPINE = ("abdomen", "thorax", "head")
MANDIBLES = ("L_mandible", "R_mandible")
LEG_BONES = [f"{t}_{l}_{p}" for t, l in ALL_LEGS for p in ("upper", "lower", "foot")]
ALL_KEYED = SPINE + MANDIBLES + tuple(LEG_BONES)


# --- Idle --------------------------------------------------------------------

def build_idle(arm, length=48):
    """A slow breathing pulse with a mandible chitter -- alive, but waiting."""
    act = new_action(arm, "Idle")
    rest(arm)
    for f in range(0, length + 1, 6):
        t = f / length
        pulse = math.sin(t * math.tau)            # one full breath per loop
        chit = math.sin(t * math.tau * 3.0)       # faster mandible twitch

        set_rot(arm.pose.bones["abdomen"], ((1, 0, 0), 2.5 * pulse))
        set_rot(arm.pose.bones["thorax"], ((1, 0, 0), -1.8 * pulse))
        set_rot(arm.pose.bones["head"], ((1, 0, 0), 2.0 * pulse))
        set_loc(arm.pose.bones["abdomen"], (0, 0, 0.016 + 0.010 * pulse))

        for tag in ("L", "R"):
            set_rot(arm.pose.bones[f"{tag}_mandible"], ((0, 0, 1), 5.0 * chit * _sign(tag)))

        # Legs settle and take the weight as the body sinks.
        for tag, leg in ALL_LEGS:
            s = _sign(tag)
            set_rot(arm.pose.bones[f"{tag}_{leg}_upper"], ((0, 1, 0), -2.0 * pulse * s))
            set_rot(arm.pose.bones[f"{tag}_{leg}_lower"], ((0, 1, 0), 3.0 * pulse * s))

        key(arm, f, ALL_KEYED, loc_bones=("abdomen",))

    set_range(act, 0, length)
    return act


# --- Run ---------------------------------------------------------------------

def _leg_gait(arm, tag, leg, phase):
    """One leg at a point in the gait cycle.

    phase 0.0-0.5 is swing (lifted, travelling forward), 0.5-1.0 is stance
    (planted, driving backward).
    """
    s = _sign(tag)
    p = phase % 1.0
    if p < 0.5:                       # swing: lift and reach forward
        k = p / 0.5
        lift = math.sin(k * math.pi) * 30.0
        # -Y is forward, so a positive world-Z yaw on the right side reaches ahead.
        swing = (-1.0 + 2.0 * k) * 20.0
        curl = math.sin(k * math.pi) * 22.0
    else:                             # stance: planted, pushing back
        k = (p - 0.5) / 0.5
        lift = 0.0
        swing = (1.0 - 2.0 * k) * 20.0
        curl = 0.0
    # Negative world-Y rotation raises a leg, so lift and curl share that sign:
    # the femur lifts, the tibia folds up under it, and the tip drops a little.
    set_rot(arm.pose.bones[f"{tag}_{leg}_upper"],
            ((0, 0, 1), swing * s), ((0, 1, 0), -lift * s))
    set_rot(arm.pose.bones[f"{tag}_{leg}_lower"], ((0, 1, 0), -curl * s))
    set_rot(arm.pose.bones[f"{tag}_{leg}_foot"], ((0, 1, 0), curl * 0.4 * s))


def build_run(arm, length=12):
    """A fast tripod skitter. Short cycle on purpose -- the mite is a swarmer."""
    act = new_action(arm, "Run")
    rest(arm)
    for f in range(0, length + 1):
        t = f / length
        for tag, leg in TRIPOD_A:
            _leg_gait(arm, tag, leg, t)
        for tag, leg in TRIPOD_B:
            _leg_gait(arm, tag, leg, t + 0.5)

        # Body bobs twice per cycle (once per tripod plant) and rolls slightly.
        bob = math.sin(t * math.tau * 2.0)
        roll = math.sin(t * math.tau)
        # The rear feet rest at exactly z=0, so abdomen down-pitch is what puts
        # them through the floor -- keep it shallow and ride the bob upward.
        set_rot(arm.pose.bones["abdomen"], ((1, 0, 0), -2.0 - 2.0 * bob), ((0, 1, 0), 3.0 * roll))
        set_rot(arm.pose.bones["thorax"], ((1, 0, 0), 2.0 + 1.5 * bob))
        set_rot(arm.pose.bones["head"], ((1, 0, 0), -3.0 - 2.0 * bob))
        set_loc(arm.pose.bones["abdomen"], (0, 0, 0.032 + 0.018 * bob))
        for tag in ("L", "R"):
            set_rot(arm.pose.bones[f"{tag}_mandible"], ((0, 0, 1), 4.0 * _sign(tag)))

        key(arm, f, ALL_KEYED, loc_bones=("abdomen",))

    set_range(act, 0, length)
    return act


# --- Attack ------------------------------------------------------------------

def build_attack(arm, length=18):
    """Windup, lunge, recover. One-shot; hive.mite's cooldown is 0.8s."""
    act = new_action(arm, "Attack")
    rest(arm)

    # The strike pitches the head down, so each beat carries its own body lift
    # to keep the mesh off the floor -- the mite plays on flat ground and any
    # dip below z=0 reads as clipping through the terrain.
    # frame: (spine pitch, shove -Y, body lift +Z, mandible spread, front-leg raise)
    beats = [
        (0,       0.0,   0.000, 0.000,  4.0,   0.0),
        (5,     -16.0,   0.055, 0.018, 34.0,  34.0),   # rear back, jaws open wide
        (8,      16.0,  -0.075, 0.045, -8.0,   6.0),   # snap forward, jaws bite shut
        (11,      8.0,  -0.030, 0.016,  2.0,  -6.0),   # follow-through
        (length,  0.0,   0.000, 0.000,  4.0,   0.0),   # settle to neutral
    ]
    # The strike's pitch lives almost entirely in the head, which sits high
    # enough to swing freely. Passing it down the spine would instead rotate
    # the legs -- and the front feet rest only 0.06 above the floor.
    for f, pitch, shove, lift, jaw, fore in beats:
        set_rot(arm.pose.bones["abdomen"], ((1, 0, 0), pitch * 0.15))
        set_rot(arm.pose.bones["thorax"], ((1, 0, 0), pitch * 0.30))
        set_rot(arm.pose.bones["head"], ((1, 0, 0), pitch))
        set_loc(arm.pose.bones["abdomen"], (0, shove, lift))

        for tag in ("L", "R"):
            s = _sign(tag)
            set_rot(arm.pose.bones[f"{tag}_mandible"], ((0, 0, 1), jaw * s))
            # Front legs rear up with the strike; the other four brace.
            set_rot(arm.pose.bones[f"{tag}_front_upper"], ((0, 1, 0), -fore * s))
            set_rot(arm.pose.bones[f"{tag}_front_lower"], ((0, 1, 0), fore * 0.6 * s))
            set_rot(arm.pose.bones[f"{tag}_front_foot"], ((0, 1, 0), -fore * 0.3 * s))
            for leg in ("mid", "rear"):
                brace = -pitch * 0.25
                set_rot(arm.pose.bones[f"{tag}_{leg}_upper"], ((0, 1, 0), brace * s))
                set_rot(arm.pose.bones[f"{tag}_{leg}_lower"], ((0, 1, 0), -brace * 1.4 * s))

        key(arm, f, ALL_KEYED, loc_bones=("abdomen",))

    set_range(act, 0, length)
    act.use_cyclic = False
    return act


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


def build_all(arm):
    bpy.context.view_layer.objects.active = arm
    for o in bpy.context.scene.objects:
        o.select_set(o is arm)
    bpy.ops.object.mode_set(mode='POSE')

    actions = [build_idle(arm), build_run(arm), build_attack(arm)]

    # Interpolate smoothly, but hold the Attack's snap frames crisp.
    for act in actions:
        for fc in action_fcurves(act):
            for kp in fc.keyframe_points:
                kp.interpolation = 'BEZIER'
                kp.handle_left_type = kp.handle_right_type = 'AUTO_CLAMPED'

    stash_to_nla(arm, actions)
    rest(arm)
    bpy.ops.object.mode_set(mode='OBJECT')
    bpy.context.scene.render.fps = FPS
    bpy.context.scene.frame_start = 0
    bpy.context.scene.frame_end = 48
    return actions
