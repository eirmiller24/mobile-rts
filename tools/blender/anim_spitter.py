"""Idle / Run / Attack actions for the Hive Spitter (units.SPITTER).

Loaded by rig_unit.py via the spec's `anim_module`; safe to re-run on an
existing rig (each build_* call replaces its action). Poses are written as
world-axis rotations per bone and baked to quaternions, so the maths reads the
way the motion looks: `(0, 0, 1)` yaws a leg fore/aft, `(0, 1, 0)` lifts it,
`(1, 0, 0)` pitches the spine.

Sign note, because this rig has bones pointing BOTH ways along Y: a positive
world-X rotation swings a bone's tail downward-forward. The thorax / neck /
head all point -Y, so +deg is nose DOWN for them; the abdomen points +Y, so
+deg raises the sac. One number, two readings -- hence `abd` is documented as
"sac up" everywhere below.

Animation direction (design.md "Art & Audio Direction"): units are read at
thumbnail size on a phone, so these favour few, high-contrast poses over
smooth realism. The spitter is the Hive's RANGED attacker, so its Attack must
never read as the mite's lunge -- see the Attack section.

Every leg hangs off `thorax`, which is also the bone Attack translates. That
means every degree of body pitch and every centimetre of body shove drags six
feet with it; the `lift` column exists to keep them out of the floor and
`make models-check` is what proves it worked.
"""

import math

import rig_lib
from rig_lib import set_rot, set_loc, sign

FPS = rig_lib.FPS

LEGS = ("front", "mid", "rear")
TRIPOD_A, TRIPOD_B = rig_lib.tripods(LEGS)
ALL_LEGS = rig_lib.all_legs(LEGS)

SPINE = ("thorax", "abdomen", "neck", "head")
FANGS = ("L_fang", "R_fang")
LEG_BONES = [f"{t}_{l}_{p}" for t, l in ALL_LEGS for p in ("upper", "lower", "foot")]
ALL_KEYED = SPINE + FANGS + tuple(LEG_BONES)
MOVED = ("thorax",)      # the only translated bone: the sim owns real position
SWELLED = ("abdomen",)   # the venom sac is the only scaled bone


def _set_body(arm, abd, thx, neck, head, shove, lift, swell, roll=0.0):
    """Spine pose from world-space quantities. `abd` is +sac up, the rest
    +nose down; `shove` is +BACKWARD (the creature faces -Y)."""
    set_rot(arm.pose.bones["thorax"], ((1, 0, 0), thx), ((0, 1, 0), roll))
    set_rot(arm.pose.bones["abdomen"], ((1, 0, 0), abd))
    set_rot(arm.pose.bones["neck"], ((1, 0, 0), neck))
    set_rot(arm.pose.bones["head"], ((1, 0, 0), head))
    set_loc(arm.pose.bones["thorax"], (0, shove, lift))
    arm.pose.bones["abdomen"].scale = (swell, swell, swell)


def _set_fangs(arm, spread):
    for tag in ("L", "R"):
        set_rot(arm.pose.bones[f"{tag}_fang"], ((0, 0, 1), spread * sign(tag)))


# --- Idle --------------------------------------------------------------------

def build_idle(arm, length=48):
    """A slow breath with a venom-sac pump: the abdomen swells and lifts while
    the front end sinks, so even standing still the silhouette breathes."""
    act = rig_lib.new_action(arm, "Idle")
    rig_lib.rest(arm)
    for f in range(0, length + 1, 4):
        t = f / length
        pulse = math.sin(t * math.tau)             # one full breath per loop
        chit = math.sin(t * math.tau * 3.0)        # faster fang twitch

        _set_body(arm,
                  abd=4.0 + 3.0 * pulse,
                  thx=-1.2 * pulse,
                  neck=2.0 * pulse,
                  head=2.5 * pulse,
                  shove=0.0,
                  # The feet are 0.95 ahead of the thorax pivot, so even a
                  # degree of nose-down buys a centimetre of sink: the base
                  # lift is what pays for the breath.
                  lift=0.046 + 0.014 * pulse,
                  swell=1.0 + 0.05 * pulse)
        _set_fangs(arm, 6.0 + 5.0 * chit)

        # Legs take the weight back as the body settles.
        for tag, leg in ALL_LEGS:
            s = sign(tag)
            set_rot(arm.pose.bones[f"{tag}_{leg}_upper"], ((0, 1, 0), -2.5 * pulse * s))
            set_rot(arm.pose.bones[f"{tag}_{leg}_lower"], ((0, 1, 0), 3.5 * pulse * s))

        rig_lib.key(arm, f, ALL_KEYED, loc_bones=MOVED, scale_bones=SWELLED)

    rig_lib.set_range(act, 0, length)
    rig_lib.smooth_action(act)
    return act


# --- Run ---------------------------------------------------------------------

def build_run(arm, length=14):
    """A high-stepping tripod scuttle. Longer cycle than the mite's: the
    spitter is speed 3.0 on much longer legs, so it strides rather than
    skitters, and the raised abdomen sways behind it."""
    act = rig_lib.new_action(arm, "Run")
    rig_lib.rest(arm)
    for f in range(0, length + 1):
        t = f / length
        for tag, leg in TRIPOD_A:
            rig_lib.leg_gait(arm, tag, leg, t, reach=24.0, lift=34.0, curl=26.0)
        for tag, leg in TRIPOD_B:
            rig_lib.leg_gait(arm, tag, leg, t + 0.5, reach=24.0, lift=34.0, curl=26.0)

        # Body bobs twice per cycle (once per tripod plant) and rolls once.
        bob = math.sin(t * math.tau * 2.0)
        roll = math.sin(t * math.tau)
        _set_body(arm,
                  abd=7.0 + 5.0 * bob,
                  thx=-1.5 - 1.5 * bob,
                  neck=1.5 + 1.5 * bob,
                  head=2.0 + 2.5 * bob,
                  shove=0.0,
                  lift=0.034 + 0.028 * bob,
                  swell=1.0,
                  # Feet sit at x = +-0.8, so body roll is the biggest single
                  # threat to ground clearance here -- keep it small and pay
                  # for it in lift.
                  roll=2.0 * roll)
        _set_fangs(arm, 8.0)

        rig_lib.key(arm, f, ALL_KEYED, loc_bones=MOVED, scale_bones=SWELLED)

    rig_lib.set_range(act, 0, length)
    rig_lib.smooth_action(act)
    return act


# --- Attack ------------------------------------------------------------------
#
# A RANGED spit, and the whole point is that it must not read as the mite's
# melee lunge. A lunge says "I closed the distance"; this has to say "I threw
# something", from 5 units away, at thumbnail size on a phone. Three beats do
# that work:
#
#   CHARGE   the creature rears onto its back legs: front legs come 72 deg off
#            the floor, the whole body slides BACKWARD and UP, the venom sac
#            swings up over the back and SWELLS to 1.28x, the fangs clamp
#            shut, and the head cocks back aiming up and forward. Held dead
#            still for three frames -- the anticipation is the longest beat.
#   SPIT     two frames. The neck/head chain uncurls and LANCES forward, the
#            sac collapses below rest scale, the fangs are flung wide open,
#            and the body slams back down flat.
#   RECOIL   the beat that sells the launch: in two frames the body is thrown
#            0.60 BACKWARD -- further and faster than it went forward -- and
#            hops 0.15 off the floor, dragging the head back behind where it
#            fired. Then it scrabbles back to neutral.
#
# Measured on the deformed mesh, against a body 1.69 long and 1.20 tall:
#   * the silhouette rears to 1.85 at the charge -- 1.54x rest height;
#   * the body centre travels +0.35 back at the charge to -0.44 forward at
#     full extension and back to +0.35 -- a 0.79 range, 47% of body length;
#   * the fang tips sweep from (y -0.36, z 1.84) at the charge to
#     (y -1.11, z 0.69) two frames later, then back to y -0.28 two frames
#     after that: 0.83 of fore/aft range and 1.63 of vertical.
# Nothing dips below the floor; the only air is the charge (0.07) and the
# recoil hop (0.15), both of which should leave the ground.
#
# Columns, all world-space:
#   abd     abdomen pitch, + swings the venom sac UP over the back
#   thx/neck/head   spine pitch, + is nose DOWN
#   shove   thorax translation along Y, + is BACKWARD
#   lift    thorax translation along Z. Every leg hangs off the thorax, so
#           this is what keeps six feet above z=0 while the body pitches.
#   swell   abdomen scale -- the sac filling and emptying
#   fang    chelicera spread, + is open, - is clamped shut
#   fore    front-leg raise, + is up
#   yaw     all-leg fore/aft yaw, + reaches forward. Planting the feet ahead
#           while the body slides back is what sells both coil and recoil.
#
#  f0 ..... f9 == f11 ==> f13 = f14 ==> f16 ..... f21 ...... f27 ... f31
#  neutral   CHARGE  hold  SPIT   slam    RECOIL   scrabble   rock    neutral
#  0.46s of windup         0.13s of release        0.63s of decelerating
#                                                  recovery
#
# The clip starts and ends on the rest pose with the body untranslated -- the
# sim owns position, so there is no root motion. Rest is keyed TWICE, on 30
# and 31: the glTF exporter's animation-size optimiser drops a final key it
# considers redundant, and the duplicate guarantees the clip Godot plays still
# ends dead on rest. 31 frames at 24fps = 1.29s, inside hive.spitter's 1.5s
# cooldown.
ATTACK_BEATS = (
    # f,   abd,   thx,  neck,  head,  shove,   lift, swell,  fang,  fore,   yaw
    (0,    0.0,   0.0,   0.0,   0.0,  0.000,  0.000,  1.00,   4.0,   0.0,   0.0),
    (3,   18.0,  -9.0, -12.0, -14.0,  0.130,  0.050,  1.08,  -6.0,  22.0,  10.0),
    (6,   40.0, -22.0, -26.0, -30.0,  0.270,  0.100,  1.18, -14.0,  52.0,  22.0),
    (9,   58.0, -32.0, -34.0, -38.0,  0.360,  0.150,  1.28, -18.0,  72.0,  30.0),  # CHARGE
    (11,  58.0, -32.0, -34.0, -38.0,  0.360,  0.150,  1.28, -18.0,  72.0,  30.0),  # hold it
    (13,  14.0,  -8.0, -12.0, -14.0, -0.150,  0.075,  1.06,  46.0,  38.0, -16.0),  # SPIT
    (14,  -8.0,   2.0,   0.0,  -2.0, -0.240,  0.026,  0.96,  58.0,  18.0, -24.0),  # slam + extend
    (16, -16.0,   4.0,   5.0,   5.0,  0.360,  0.085,  1.00,  34.0,  40.0,  24.0),  # RECOIL
    (18,  -6.0,  -3.0,  -2.0,  -2.0,  0.260,  0.045,  1.03,  16.0,  24.0,  28.0),
    (21,  10.0,  -5.0,  -7.0,  -8.0,  0.090,  0.030,  1.05,   9.0,   9.0,  11.0),
    (24,  -4.0,   2.0,   3.0,   4.0, -0.050,  0.012,  0.99,   3.0,   2.0,  -5.0),
    (27,   3.0,  -1.0,  -1.0,  -2.0,  0.020,  0.005,  1.01,   4.0,   1.0,   2.0),
    (30,   0.0,   0.0,   0.0,   0.0,  0.000,  0.000,  1.00,   4.0,   0.0,   0.0),  # home
    (31,   0.0,   0.0,   0.0,   0.0,  0.000,  0.000,  1.00,   4.0,   0.0,   0.0),  # and hold
)
ATTACK_LENGTH = ATTACK_BEATS[-1][0]


def build_attack(arm):
    """Charge, spit, recoil, settle. One-shot; 31 frames at 24fps = 1.29s,
    inside hive.spitter's 1.5s cooldown."""
    act = rig_lib.new_action(arm, "Attack")
    rig_lib.rest(arm)

    for f, abd, thx, neck, head, shove, lift, swell, fang, fore, yaw in ATTACK_BEATS:
        _set_body(arm, abd, thx, neck, head, shove, lift, swell)
        _set_fangs(arm, fang)

        for tag in ("L", "R"):
            s = sign(tag)
            # Front legs rear right off the floor with the charge and slam
            # down as the recoil drives the body back.
            set_rot(arm.pose.bones[f"{tag}_front_upper"],
                    ((0, 0, 1), yaw * 1.3 * s), ((0, 1, 0), -fore * s))
            set_rot(arm.pose.bones[f"{tag}_front_lower"], ((0, 1, 0), fore * 0.55 * s))
            set_rot(arm.pose.bones[f"{tag}_front_foot"], ((0, 1, 0), -fore * 0.3 * s))
            # Mids brace: a little lift, mostly yaw.
            set_rot(arm.pose.bones["%s_mid_upper" % tag],
                    ((0, 0, 1), yaw * s), ((0, 1, 0), -fore * 0.22 * s))
            set_rot(arm.pose.bones["%s_mid_lower" % tag], ((0, 1, 0), fore * 0.16 * s))
            # Rears stay planted and take the whole recoil, so they get pure
            # world-Z yaw: the foot sweeps along the floor at a constant
            # height instead of being levered off it.
            set_rot(arm.pose.bones["%s_rear_upper" % tag], ((0, 0, 1), yaw * 0.8 * s))
            set_rot(arm.pose.bones["%s_rear_lower" % tag], ((0, 1, 0), -yaw * 0.12 * s))

        rig_lib.key(arm, f, ALL_KEYED, loc_bones=MOVED, scale_bones=SWELLED)

    rig_lib.set_range(act, 0, ATTACK_LENGTH, cyclic=False)

    # Timing is the other half of the read. Default bezier eases out of every
    # key, which turns both the spit and the recoil into drifts. The charge
    # arrives without overshooting (vector handles on 9), holds dead still to
    # 11, then leaves 11 LINEAR so the spit travels at full speed from its
    # first frame; 14 leaves LINEAR too so the recoil snaps, and 16 stops it
    # with a hard corner.
    rig_lib.smooth_action(act)
    rig_lib.ease_out_of(act, 9)
    rig_lib.set_frame_interp(act, 11, 'LINEAR')
    rig_lib.set_frame_interp(act, 13, 'LINEAR')
    rig_lib.set_frame_interp(act, 14, 'LINEAR')
    rig_lib.ease_out_of(act, 16)
    return act


# --- assembly ----------------------------------------------------------------

def build_all(arm, spec=None):
    rig_lib.enter_pose_mode(arm)
    actions = [build_idle(arm), build_run(arm), build_attack(arm)]
    return rig_lib.finalize(arm, actions)
