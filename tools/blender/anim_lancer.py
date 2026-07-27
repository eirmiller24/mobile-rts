"""Idle / Run / Attack actions for the Hive Lancer (units.LANCER).

Loaded by rig_unit.py via the spec's `anim_module`; safe to re-run on an
existing rig (each build_* call replaces its action). Poses are written as
world-axis rotations per bone and baked to quaternions, so the maths reads the
way the motion looks: `(0, 0, 1)` yaws a bone left/right, `(0, 1, 0)` lifts a
leg, `(1, 0, 0)` pitches the spine.

Sign note, because this rig has bones pointing BOTH ways along Y: a positive
world-X rotation swings a bone's tail downward. The thorax / neck / head /
tusks point -Y, so +deg is nose DOWN for them; `hind` / `tail` / `tail_tip`
point +Y, so +deg lifts the rear end and the tail. Every column below says
which reading it uses.

Animation direction (design.md "Art & Audio Direction"): units are read at
thumbnail size on a phone, so these favour few, high-contrast poses over
smooth realism. The lancer is the Hive's ARMOURED melee shock trooper and the
biggest unit modelled -- so where the mite is frantic and the spitter recoils,
this one is DELIBERATE: a long, heavy windup, an explosive thrust, and a
settle that lags behind the body.

Ground clearance is the tightest of any unit here: the rear feet sit only
0.072 above the floor in the rest mesh and all six hang off the spine, so
every degree of pitch has to be paid for in `lift`. That is what the `hind`
bone is for -- see `_set_body`.
"""

import math

import rig_lib
from rig_lib import set_rot, set_loc, sign

FPS = rig_lib.FPS

LEGS = ("front", "mid", "rear")
TRIPOD_A, TRIPOD_B = rig_lib.tripods(LEGS)
ALL_LEGS = rig_lib.all_legs(LEGS)

SPINE = ("thorax", "hind", "tail", "tail_tip", "neck", "head")
TUSKS = ("L_tusk", "R_tusk")
LEG_BONES = [f"{t}_{l}_{p}" for t, l in ALL_LEGS for p in ("upper", "lower", "foot")]
ALL_KEYED = SPINE + TUSKS + tuple(LEG_BONES)
MOVED = ("thorax",)      # the only translated bone: the sim owns real position
FLARED = ("head",)       # scaled, for the shock discharge on impact


def _set_body(arm, thx, hind, tailp, tipp, neck, head,
              shove, lift, roll=0.0, tail_yaw=0.0, flare=1.0):
    """Spine pose from world-space quantities.

    `thx` / `neck` / `head` are + nose DOWN; `tailp` / `tipp` are + tail UP;
    `shove` is + BACKWARD (the creature faces -Y); `lift` is + up.

    `hind` is the WORLD pitch of the rear section, + rear UP -- not a local
    value. Rotations about a shared axis commute down the pose chain, so
    subtracting the thorax's pitch here means "hold the rear legs at this
    angle to the FLOOR whatever the front is doing". Without that, a 22 deg
    rear-up windup would drag the rear feet 0.20 through the terrain.
    """
    set_rot(arm.pose.bones["thorax"], ((1, 0, 0), thx), ((0, 1, 0), roll))
    set_rot(arm.pose.bones["hind"], ((1, 0, 0), hind - thx))
    set_rot(arm.pose.bones["tail"], ((1, 0, 0), tailp), ((0, 0, 1), tail_yaw))
    set_rot(arm.pose.bones["tail_tip"], ((1, 0, 0), tipp), ((0, 0, 1), tail_yaw * 0.6))
    set_rot(arm.pose.bones["neck"], ((1, 0, 0), neck))
    set_rot(arm.pose.bones["head"], ((1, 0, 0), head))
    set_loc(arm.pose.bones["thorax"], (0, shove, lift))
    arm.pose.bones["head"].scale = (flare, flare, flare)


def _set_tusks(arm, spread, pitch):
    """`spread` is + apart / - clamped shut; `pitch` is + points DOWN.

    The tusks rest 46 deg below horizontal, so a NEGATIVE pitch is what
    levels them into a forward-pointing spear.
    """
    for tag in ("L", "R"):
        set_rot(arm.pose.bones[f"{tag}_tusk"],
                ((0, 0, 1), spread * sign(tag)), ((1, 0, 0), pitch))


# --- Idle --------------------------------------------------------------------

def build_idle(arm, length=60):
    """A slow, heavy breath: 2.5s per loop against the mite's 2.0 and the
    spitter's 2.0. The carapace rises, the head sinks to compensate, and the
    tail rolls through a lazy S -- armour idling, not an insect twitching."""
    act = rig_lib.new_action(arm, "Idle")
    rig_lib.rest(arm)
    for f in range(0, length + 1, 4):
        t = f / length
        pulse = math.sin(t * math.tau)             # one full breath per loop
        sway = math.sin(t * math.tau - 0.9)        # tail lags the breath
        chit = math.sin(t * math.tau * 2.0)        # slow tusk flex

        _set_body(arm,
                  thx=-1.2 * pulse,
                  hind=-0.9 * pulse,
                  tailp=7.0 + 6.0 * pulse,
                  tipp=6.0 + 7.0 * pulse,
                  neck=-2.2 * pulse,
                  head=3.0 * pulse,
                  shove=0.0,
                  # Rest feet clear the floor by 0.022 (front/mid) and 0.072
                  # (rear), so the base lift is what pays for the breath.
                  lift=0.052 + 0.016 * pulse,
                  tail_yaw=5.0 * sway)
        _set_tusks(arm, 9.0 + 6.0 * chit, -3.0 + 5.0 * pulse)

        # Legs take the weight back as the body settles.
        for tag, leg in ALL_LEGS:
            s = sign(tag)
            set_rot(arm.pose.bones[f"{tag}_{leg}_upper"], ((0, 1, 0), -2.2 * pulse * s))
            set_rot(arm.pose.bones[f"{tag}_{leg}_lower"], ((0, 1, 0), 3.2 * pulse * s))

        rig_lib.key(arm, f, ALL_KEYED, loc_bones=MOVED)

    rig_lib.set_range(act, 0, length)
    rig_lib.smooth_action(act)
    return act


# --- Run ---------------------------------------------------------------------

def build_run(arm, length=16):
    """A heavy tripod stride. The longest cycle of the three units (0.67s
    against the mite's 0.50 and the spitter's 0.58) with the biggest reach:
    speed 3.2 on a 1.6-tall armoured body is a march, not a skitter. The tail
    counter-swings against the body roll so the silhouette is never static."""
    act = rig_lib.new_action(arm, "Run")
    rig_lib.rest(arm)
    for f in range(0, length + 1):
        t = f / length
        for tag, leg in TRIPOD_A:
            rig_lib.leg_gait(arm, tag, leg, t, reach=27.0, lift=33.0, curl=28.0)
        for tag, leg in TRIPOD_B:
            rig_lib.leg_gait(arm, tag, leg, t + 0.5, reach=27.0, lift=33.0, curl=28.0)

        # Body bobs twice per cycle (once per tripod plant), rolls once.
        bob = math.sin(t * math.tau * 2.0)
        roll = math.sin(t * math.tau)
        _set_body(arm,
                  thx=-2.5 - 2.5 * bob,
                  hind=-1.2 - 1.6 * bob,
                  tailp=9.0 + 7.0 * bob,
                  tipp=7.0 + 6.0 * bob,
                  neck=-3.0 - 3.0 * bob,
                  head=4.0 + 5.0 * bob,
                  shove=0.0,
                  lift=0.058 + 0.030 * bob,
                  # Feet sit out to x = +-0.61, so roll is the biggest single
                  # threat to ground clearance -- keep it small, pay in lift.
                  roll=1.8 * roll,
                  tail_yaw=-7.0 * roll)
        _set_tusks(arm, 11.0 + 5.0 * bob, -5.0)

        rig_lib.key(arm, f, ALL_KEYED, loc_bones=MOVED)

    rig_lib.set_range(act, 0, length)
    rig_lib.smooth_action(act)
    return act


# --- Attack ------------------------------------------------------------------
#
# A committed, heavy LANCING thrust -- the one motion this creature's geometry
# is actually for. It must not read as the mite's frantic bite or the
# spitter's recoiling spit; the beats are deliberately slower into the windup
# and laggier out of the hit, because the lancer is armoured, not frantic.
#
#   COIL     0.46s, the longest beat. The body rocks back over its rear legs
#            and rears: front legs come 60 deg off the floor, the thorax
#            pitches 30 deg nose-up while `hind` holds the rear feet down, the
#            tail arcs up over the back like a scorpion's, and the head hauls
#            back so the two tusks swing from 46 deg BELOW horizontal to 60
#            deg ABOVE it -- raised lances, flung 50 deg apart. Held dead
#            still for a frame; that stillness is the "heavy" read.
#   THRUST   2 frames. The whole creature is thrown 1.26 forward and pitches
#            20 deg nose-DOWN while the tusks level out to a spear: from
#            brandished overhead to dead ahead in three frames.
#   SHOCK    1 frame. Damage class is "shock": on the frame after contact the
#            tusks fling 62 deg apart, the head flares to 1.10x, and the body
#            judders -- an electric discharge at the point of impact.
#   SETTLE   0.46s of recovery that LAGS: the body stays dug in, heaves back,
#            SLAMS down flat on all six at f21, then rebounds and rocks home.
#
# Measured on the deformed mesh, against a body 1.73 long and 1.60 tall (the
# numbers come from a per-frame pass over the same evaluated mesh
# tools/blender/ground_check.py walks):
#   * the silhouette rears to 2.08 at the coil -- 1.30x rest height -- and
#     collapses to 1.63 three frames later at full extension, a 1.28:1 swing
#     between the two poses that matter;
#   * the body centre travels +0.50 back at the coil to -0.76 forward at full
#     extension -- 1.26, 73% of the creature's own body length (the mite's
#     lunge is ~60%, the spitter's spit ~47%);
#   * the tusk tips sweep from (y +0.26, z 1.99) brandished over the back to
#     (y -1.73, z 0.97) speared out front: 1.99 of reach -- more than a whole
#     body length -- and 1.31 of drop, in four frames.
# Nothing dips below the floor: the only air is the coil (0.17) and the leap
# itself (0.09-0.24), both of which should leave the ground.
#
# Columns, all world-space unless noted:
#   thx      thorax pitch, + nose DOWN
#   hind     rear-section pitch relative to the FLOOR, + rear up (see
#            `_set_body`: this is what keeps six feet out of the terrain)
#   tailp    tail pitch, + tail up;  tipp  the same for the tail tip
#   neck/head  spine pitch, + nose DOWN (local, so they compound down the arm)
#   shove    thorax translation along Y, + is BACKWARD
#   lift     thorax translation along Z. Rising is free; sinking clips.
#   tsp      tusk spread, + apart, - crossed shut
#   tp       tusk pitch, + points down. Rest is 46 deg below horizontal, and
#            these all compound down the chain, so the angle the tusks
#            actually make with the floor is 46 + thx + neck + head + tp:
#            -106 at the coil (brandished overhead), -50 at the impale
#            (a level spear, 4 deg below horizontal).
#   fore     front-leg raise, + up. Also the ground-clearance lever on the
#            strike: it holds the front feet up while the body dives.
#   yaw      all-leg fore/aft yaw, + reaches forward. Planting the feet ahead
#            while the body slides back is what sells the coil.
#   flare    head scale -- the shock discharge, one frame only.
#
#  f0 ....... f11 = f12 ==> f14 = f15 => f16 ... f18 ... f21 .. f23 .. f27
#  neutral    COIL   hold  THRUST  IMPALE SHOCK  dug in  SLAM  rebound neutral
#  0.46s of windup         0.13s of strike       0.46s of lagging recovery
#
# The clip starts and ends on the rest pose with the body untranslated -- the
# sim owns position, so there is no root motion. Rest is keyed TWICE, on 26
# and 27: the glTF exporter's animation-size optimiser drops a final key it
# considers redundant, and the duplicate guarantees the clip Godot plays still
# ends dead on rest. 27 frames at 24fps = 1.125s, inside hive.lancer's 1.2s
# cooldown.
ATTACK_BEATS = (
    # f,  thx, hind, tailp, tipp, neck, head,  shove,   lift,  tsp,   tp, fore,  yaw, flare
    (0,   0.0,  0.0,   0.0,  0.0,  0.0,  0.0,  0.000,  0.000,  8.0,  0.0,  0.0,  0.0, 1.00),
    (3,  -8.0, -4.0,  11.0,  9.0, -7.0, -8.0,  0.130,  0.055, 20.0, -4.0, 13.0, 10.0, 1.00),
    (7, -19.0, -9.0,  28.0, 22.0,-16.0,-19.0,  0.300,  0.125, 36.0,-10.0, 37.0, 23.0, 1.00),
    (11,-30.0,-14.0,  46.0, 36.0,-26.0,-30.0,  0.440,  0.260, 50.0,-20.0, 60.0, 34.0, 1.00),  # COIL
    (12,-30.0,-14.0,  46.0, 36.0,-26.0,-30.0,  0.440,  0.260, 50.0,-20.0, 60.0, 34.0, 1.00),  # hold
    (14, 14.0,  7.0, -10.0, -8.0,  0.0,  0.0, -0.500,  0.170, 26.0,-66.0, 28.0,-30.0, 1.00),  # THRUST
    (15, 20.0, 10.0, -20.0,-15.0,  2.0,  4.0, -0.680,  0.175, 14.0,-76.0, 34.0,-40.0, 1.00),  # IMPALE
    (16, 18.0,  9.0, -16.0,-12.0,  1.0,  2.0, -0.640,  0.175, 62.0,-61.0, 32.0,-36.0, 1.10),  # SHOCK
    (18, 12.0,  6.0, -18.0,-13.0,  6.0, 10.0, -0.400,  0.125, 40.0,-42.0, 20.0,-24.0, 1.00),  # dug in
    (21,  0.0,  0.0,  -8.0, -6.0,  2.0,  4.0, -0.120,  0.010, 20.0,-14.0, 18.0, 14.0, 1.00),  # SLAM down
    (23, -8.0, -4.0,  18.0, 14.0,-12.0,-16.0,  0.180,  0.075, 12.0, -6.0, 18.0, 21.0, 1.00),  # rebound/sag
    (25,  2.0,  1.0,  -6.0, -5.0,  4.0,  5.0, -0.030,  0.038,  6.0,  3.0,  2.0, -4.0, 1.00),  # rock
    (26,  0.0,  0.0,   0.0,  0.0,  0.0,  0.0,  0.000,  0.000,  8.0,  0.0,  0.0,  0.0, 1.00),  # home
    (27,  0.0,  0.0,   0.0,  0.0,  0.0,  0.0,  0.000,  0.000,  8.0,  0.0,  0.0,  0.0, 1.00),  # hold
)
ATTACK_LENGTH = ATTACK_BEATS[-1][0]


def build_attack(arm):
    """Coil, lance, discharge, settle. One-shot; 27 frames at 24fps = 1.125s,
    inside hive.lancer's 1.2s cooldown."""
    act = rig_lib.new_action(arm, "Attack")
    rig_lib.rest(arm)

    for (f, thx, hind, tailp, tipp, neck, head,
         shove, lift, tsp, tp, fore, yaw, flare) in ATTACK_BEATS:
        _set_body(arm, thx, hind, tailp, tipp, neck, head, shove, lift, flare=flare)
        _set_tusks(arm, tsp, tp)

        for tag in ("L", "R"):
            s = sign(tag)
            # Front legs rear right off the floor with the coil and reach out
            # ahead of the body as it lands.
            set_rot(arm.pose.bones[f"{tag}_front_upper"],
                    ((0, 0, 1), yaw * 1.3 * s), ((0, 1, 0), -fore * s))
            set_rot(arm.pose.bones[f"{tag}_front_lower"], ((0, 1, 0), fore * 0.55 * s))
            set_rot(arm.pose.bones[f"{tag}_front_foot"], ((0, 1, 0), -fore * 0.3 * s))
            # Mids brace: a little lift, mostly yaw.
            set_rot(arm.pose.bones[f"{tag}_mid_upper"],
                    ((0, 0, 1), yaw * s), ((0, 1, 0), -fore * 0.20 * s))
            set_rot(arm.pose.bones[f"{tag}_mid_lower"], ((0, 1, 0), fore * 0.15 * s))
            # Rears stay planted and drive the whole thrust, so they get pure
            # world-Z yaw: the foot sweeps along the floor at a constant
            # height instead of being levered off it.
            set_rot(arm.pose.bones[f"{tag}_rear_upper"], ((0, 0, 1), yaw * 0.85 * s))
            set_rot(arm.pose.bones[f"{tag}_rear_lower"], ((0, 1, 0), -yaw * 0.12 * s))

        rig_lib.key(arm, f, ALL_KEYED, loc_bones=MOVED, scale_bones=FLARED)

    rig_lib.set_range(act, 0, ATTACK_LENGTH, cyclic=False)

    # Timing is the other half of the read. Default bezier eases out of every
    # key, which turns the thrust into a drift. The coil arrives without
    # overshooting (vector handles on 11), holds dead still to 12, then leaves
    # 12 LINEAR so the lance travels at full speed from its very first frame;
    # 14 and 15 leave LINEAR too so the impale and the shock snap are hard
    # corners rather than eased arcs.
    rig_lib.smooth_action(act)
    rig_lib.ease_out_of(act, 11)
    rig_lib.set_frame_interp(act, 12, 'LINEAR')
    rig_lib.set_frame_interp(act, 14, 'LINEAR')
    rig_lib.set_frame_interp(act, 15, 'LINEAR')
    rig_lib.ease_out_of(act, 16)
    return act


# --- assembly ----------------------------------------------------------------

def build_all(arm, spec=None):
    rig_lib.enter_pose_mode(arm)
    actions = [build_idle(arm), build_run(arm), build_attack(arm)]
    return rig_lib.finalize(arm, actions)
