"""Idle / Run / Attack actions for the Hive Mite (units.MITE).

Loaded by rig_unit.py via the spec's `anim_module`; safe to re-run on an
existing rig (each build_* call replaces its action). Poses are written as
world-axis rotations per bone and baked to quaternions, so the maths reads the
way the motion looks: `(0, 0, 1)` yaws a leg fore/aft, `(0, 1, 0)` lifts it,
`(1, 0, 0)` pitches the spine (positive = nose down).

Animation direction (design.md "Art & Audio Direction"): the budget is small
and units are read at thumbnail size on a phone, so these favour few,
high-contrast poses over smooth realism -- the Hive "skitters and pulses".
"""

import math

import rig_lib
from rig_lib import set_rot, set_loc, sign

FPS = rig_lib.FPS

LEGS = ("front", "mid", "rear")
TRIPOD_A, TRIPOD_B = rig_lib.tripods(LEGS)
ALL_LEGS = rig_lib.all_legs(LEGS)

SPINE = ("abdomen", "thorax", "head")
MANDIBLES = ("L_mandible", "R_mandible")
LEG_BONES = [f"{t}_{l}_{p}" for t, l in ALL_LEGS for p in ("upper", "lower", "foot")]
ALL_KEYED = SPINE + MANDIBLES + tuple(LEG_BONES)


# --- Idle --------------------------------------------------------------------

def build_idle(arm, length=48):
    """A slow breathing pulse with a mandible chitter -- alive, but waiting."""
    act = rig_lib.new_action(arm, "Idle")
    rig_lib.rest(arm)
    for f in range(0, length + 1, 6):
        t = f / length
        pulse = math.sin(t * math.tau)            # one full breath per loop
        chit = math.sin(t * math.tau * 3.0)       # faster mandible twitch

        set_rot(arm.pose.bones["abdomen"], ((1, 0, 0), 2.5 * pulse))
        set_rot(arm.pose.bones["thorax"], ((1, 0, 0), -1.8 * pulse))
        set_rot(arm.pose.bones["head"], ((1, 0, 0), 2.0 * pulse))
        set_loc(arm.pose.bones["abdomen"], (0, 0, 0.016 + 0.010 * pulse))

        for tag in ("L", "R"):
            set_rot(arm.pose.bones[f"{tag}_mandible"], ((0, 0, 1), 5.0 * chit * sign(tag)))

        # Legs settle and take the weight as the body sinks.
        for tag, leg in ALL_LEGS:
            s = sign(tag)
            set_rot(arm.pose.bones[f"{tag}_{leg}_upper"], ((0, 1, 0), -2.0 * pulse * s))
            set_rot(arm.pose.bones[f"{tag}_{leg}_lower"], ((0, 1, 0), 3.0 * pulse * s))

        rig_lib.key(arm, f, ALL_KEYED, loc_bones=("abdomen",))

    rig_lib.set_range(act, 0, length)
    rig_lib.smooth_action(act)
    return act


# --- Run ---------------------------------------------------------------------

def build_run(arm, length=12):
    """A fast tripod skitter. Short cycle on purpose -- the mite is a swarmer."""
    act = rig_lib.new_action(arm, "Run")
    rig_lib.rest(arm)
    for f in range(0, length + 1):
        t = f / length
        for tag, leg in TRIPOD_A:
            rig_lib.leg_gait(arm, tag, leg, t)
        for tag, leg in TRIPOD_B:
            rig_lib.leg_gait(arm, tag, leg, t + 0.5)

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
            set_rot(arm.pose.bones[f"{tag}_mandible"], ((0, 0, 1), 4.0 * sign(tag)))

        rig_lib.key(arm, f, ALL_KEYED, loc_bones=("abdomen",))

    rig_lib.set_range(act, 0, length)
    rig_lib.smooth_action(act)
    return act


# --- Attack ------------------------------------------------------------------
#
# A Zergling-grade lunge: coil, a held windup, then a two-frame strike that
# throws the whole body half its own length forward, overshoots, and recovers.
# The subtle version this replaced (16 deg of pitch, 0.075 of shove) was
# invisible at thumbnail size on a phone, which is the only size that matters.
# Measured on the deformed mesh: the body centre travels +0.18 back at the coil
# to -0.38 forward at full extension -- 0.56, well over half the mite's own
# length -- and the silhouette rears to 1.18 tall (rest is 0.90) before it
# stretches out low. Nothing dips below the floor; the strike is a real leap.
#
# Every column is a world-space quantity:
#   abd/thx/head  spine pitch in degrees, +down. Held mostly in the head and
#                 thorax on the strike: pitch on the abdomen swings the rear
#                 legs, whose feet rest ON the floor.
#   shove         body translation along Y, + is BACKWARD (the mite faces -Y).
#   lift          body translation along Z. Rising is free; sinking clips.
#   jaw           mandible spread, + is open.
#   fore          front-leg raise, + is up.
#   yaw           all-leg fore/aft yaw, + reaches forward. Planting the legs
#                 ahead while the body slides back is what sells the coil, and
#                 it costs nothing in ground clearance.
#
#  f0 ..... f3 ......... f7 = f8 ==> f10 => f12 .. f15 ... f17 ... f19
#  neutral  coil         WINDUP hold  STRIKE  land   back   rock    neutral
#           0.33s of windup           0.17s   0.29s of decelerating recovery
#
# The clip must start and end on the rest pose and leave the body untranslated
# -- the sim owns position, so the last beats are f0 exactly and there is no
# root motion. Rest is keyed TWICE, on 18 and 19: the glTF exporter's
# animation-size optimiser drops a final key it considers redundant, and the
# duplicate is what guarantees the clip Godot plays still ends dead on rest
# (it lands as a 0.75s clip inside the 0.8s cooldown).
ATTACK_BEATS = (
    # f, abd,  thx,  head, shove,  lift,  jaw, fore,  yaw
    (0, 0.0, 0.0, 0.0, 0.000, 0.000, 4.0, 0.0, 0.0),
    (3, -5.0, -9.0, -14.0, 0.070, 0.010, 26.0, 14.0, 7.0),
    (7, -13.0, -24.0, -40.0, 0.200, 0.095, 56.0, 50.0, 20.0),
    (8, -13.0, -24.0, -40.0, 0.200, 0.095, 56.0, 50.0, 20.0),   # hold the coil
    (10, 3.0, 9.0, 44.0, -0.300, 0.130, -14.0, 16.0, -24.0),    # STRIKE
    (12, 3.0, 7.0, 30.0, -0.365, 0.070, -10.0, 4.0, -20.0),     # overshoot, land
    (15, -2.0, -3.0, -6.0, -0.150, 0.028, 10.0, 8.0, -6.0),     # scrabble back
    (17, 1.0, 2.0, 4.0, 0.030, 0.016, 8.0, 2.0, 4.0),           # rock past neutral
    (18, 0.0, 0.0, 0.0, 0.000, 0.000, 4.0, 0.0, 0.0),           # home
    (19, 0.0, 0.0, 0.0, 0.000, 0.000, 4.0, 0.0, 0.0),           # and hold it
)
ATTACK_LENGTH = ATTACK_BEATS[-1][0]


def build_attack(arm):
    """Windup, lunge, recover. One-shot; hive.mite's cooldown is 0.8s and this
    is 19 frames at 24fps = 0.79s, so the clip lands just inside it."""
    act = rig_lib.new_action(arm, "Attack")
    rig_lib.rest(arm)

    for f, abd, thx, head, shove, lift, jaw, fore, yaw in ATTACK_BEATS:
        set_rot(arm.pose.bones["abdomen"], ((1, 0, 0), abd))
        set_rot(arm.pose.bones["thorax"], ((1, 0, 0), thx))
        set_rot(arm.pose.bones["head"], ((1, 0, 0), head))
        set_loc(arm.pose.bones["abdomen"], (0, shove, lift))

        for tag in ("L", "R"):
            s = sign(tag)
            set_rot(arm.pose.bones[f"{tag}_mandible"], ((0, 0, 1), jaw * s))
            # Front legs rear right up with the coil and slam down on contact.
            set_rot(arm.pose.bones[f"{tag}_front_upper"],
                    ((0, 0, 1), yaw * 1.2 * s), ((0, 1, 0), -fore * s))
            set_rot(arm.pose.bones[f"{tag}_front_lower"], ((0, 1, 0), fore * 0.6 * s))
            set_rot(arm.pose.bones[f"{tag}_front_foot"], ((0, 1, 0), -fore * 0.3 * s))
            # The other four stay on the floor and drive: yaw only.
            for leg in ("mid", "rear"):
                set_rot(arm.pose.bones[f"{tag}_{leg}_upper"], ((0, 0, 1), yaw * s))
                set_rot(arm.pose.bones[f"{tag}_{leg}_lower"], ((0, 1, 0), -yaw * 0.25 * s))

        rig_lib.key(arm, f, ALL_KEYED, loc_bones=("abdomen",))

    rig_lib.set_range(act, 0, ATTACK_LENGTH, cyclic=False)

    # Timing is the other half of the read. Default bezier eases out of every
    # key, which turns the strike into a drift; the coil holds dead still on
    # 7-8 and then leaves frame 8 LINEAR, so the two-frame lunge travels at
    # full speed from the first frame and stops hard on contact.
    rig_lib.smooth_action(act)
    rig_lib.set_frame_interp(act, 8, 'LINEAR')
    rig_lib.set_frame_interp(act, 10, 'LINEAR')
    rig_lib.ease_out_of(act, 7)     # arrive at the coil without overshooting it
    rig_lib.ease_out_of(act, 12)
    return act


# --- assembly ----------------------------------------------------------------

def build_all(arm, spec=None):
    rig_lib.enter_pose_mode(arm)
    actions = [build_idle(arm), build_run(arm), build_attack(arm)]
    return rig_lib.finalize(arm, actions)
