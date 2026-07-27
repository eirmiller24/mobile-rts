"""Clips for the Hive Carapace (units.CARAPACE) -- the one unit with two forms.

Loaded by rig_unit.py via the spec's `anim_module`; safe to re-run on an
existing rig (each build_* call replaces its action). Poses are written as
world-axis rotations per bone and baked to quaternions, so the maths reads the
way the motion looks: `(0, 0, 1)` yaws a bone left/right, `(0, 1, 0)` lifts a
leg, `(1, 0, 0)` pitches the spine.

Sign note: every bone on this rig points -Y or outward, so a positive world-X
rotation always swings a bone's tail DOWN -- + is nose-down for `thorax`,
`head` and `turret` alike. (The lancer needed a paragraph here because its
`hind`/`tail` pointed the other way; nothing on this rig does.)

hive.root makes this creature a walking melee tank that anchors into an
immobile ranged turret: morphed it loses all speed and gains damage 10 -> 25,
range 0.6 -> 4.0 and hits_air. So there are two neutral poses, not one, and
six clips:

    walking form   Idle    Run    Attack          (mandible bite, range 0.6)
    transition     Root                           (1.5s, matches morph_time)
    anchored form  Rooted  RootedAttack           (cannon shot, range 4.0)

Every clip starts and ends on ITS OWN form's neutral pose with no net
translation -- the sim owns position. `Root` is the single exception and the
reason both neutrals are functions rather than literals: it starts on
`_walk_neutral` and ends on `_anchored`, and `Rooted` / `RootedAttack` open on
that same `_anchored` pose, so the three cannot drift apart and the morph
cannot pop. tests/ has no Blender, so continuity is asserted in the build log
by comparing the deformed mesh at the boundary frames.

Animation direction (design.md "Art & Audio Direction"): units are read at
thumbnail size on a phone, so these favour few, high-contrast poses over
smooth realism. Two things carry the morph at that size, both measured on the
deformed mesh at the two neutral poses:

  * the CANNON. Stowed 24 deg nose-down while walking, locked 26 deg nose-UP
    when rooted. The barrel tip goes from (y -0.65, z 0.88) to (y -0.54,
    z 1.36) -- it rises 0.48 in world terms and 0.77 relative to the body that
    dropped underneath it, on a creature only 1.4 tall.
  * the STANCE. Rooted, the carapace sinks 0.29 (its dome top falls 1.05 ->
    0.76, a fifth of the whole model height) and the feet splay from x +-0.66
    to +-0.89, taking the silhouette from 1.42 wide to 1.83. Tall-and-narrow
    becomes low-and-wide, which is the change that survives the 55 deg RTS
    camera.

Ground clearance is the tightest of any unit here -- the left middle foot sits
at z = 0.000 in the rest mesh -- so every pose carries a base `lift` and the
rooted crouch buys its sink by splaying the feet OUT (each leg is at 0.64 of
its 0.66 straightened reach at rest, so folding is the only slack available).
Worst floor clearance per clip, in the order they are built: +0.021, +0.016,
+0.012, +0.011, +0.026, +0.006. `make models-check` is the backstop.
"""

import math

import rig_lib
from rig_lib import set_rot, set_loc, sign

FPS = rig_lib.FPS

LEGS = ("front", "mid", "rear")
TRIPOD_A, TRIPOD_B = rig_lib.tripods(LEGS)
ALL_LEGS = rig_lib.all_legs(LEGS)

SPINE = ("thorax", "head", "turret", "barrel")
FANGS = ("L_fang", "R_fang")
LEG_BONES = [f"{t}_{l}_{p}" for t, l in ALL_LEGS for p in ("upper", "lower", "foot")]
ALL_KEYED = SPINE + FANGS + tuple(LEG_BONES)
# Translated bones: the thorax (the whole creature shoving/sinking) and the
# barrel (recoil along its own axis). The sim owns real position, so both
# return to zero at the end of every clip.
MOVED = ("thorax", "barrel")
# Scaled bones: the head flares on the bite, the barrel on the muzzle blast.
FLARED = ("head", "barrel")

# Base thorax lift, in every walking pose. The rest mesh has a foot at exactly
# z = 0.000, so without this any breath at all clips through the terrain.
WALK_LIFT = 0.035

# Cannon pitch, + nose DOWN. The single most legible difference between the
# two forms; see the module docstring.
TURRET_STOW = 24.0
TURRET_DEPLOY = -26.0

# The anchored stance, and the numbers that make it possible. Each leg is
# already at 0.64 of its 0.66 straightened reach at rest, so it cannot push the
# body DOWN -- the only way to sink is to fold the leg and throw the foot
# OUTWARD, which raises the tip relative to the hip. Measured on the rig (right
# middle leg, tip height above the hip's rest plane):
#
#       fold=0   fold=+30   fold=+45
#   up=0   0.031     0.137      0.209
#   up=20  0.210     0.349      0.428
#   up=30  0.314     0.464      0.542
#
# ... and the tip travels from x 0.66 out to x 0.88 doing it. So `up` +
# `fold` buy sink and width at the same time, which is exactly the rooted
# read: the thorax drops ROOT_LIFT and every foot lands wide.
ROOT_LIFT = -0.255
ROOT_PITCH = 3.0
ROOT_LEGS = {
    #          up,   yaw,  fold,  foot
    "front": (34.0,  24.0, 38.0,  -8.0),
    "mid":   (22.0,   0.0, 34.0,  -6.0),
    "rear":  (28.0, -24.0, 36.0,  -8.0),
}


# --- pose primitives ---------------------------------------------------------

def _set_body(arm, pitch=0.0, roll=0.0, shove=0.0, lift=0.0,
              head=0.0, flare=1.0):
    """Thorax + head. `pitch`/`head` are + nose DOWN, `shove` is + BACKWARD
    (the creature faces -Y), `lift` is + up, `flare` scales the head."""
    set_rot(arm.pose.bones["thorax"], ((1, 0, 0), pitch), ((0, 1, 0), roll))
    set_loc(arm.pose.bones["thorax"], (0, shove, lift))
    set_rot(arm.pose.bones["head"], ((1, 0, 0), head))
    arm.pose.bones["head"].scale = (flare, flare, flare)


def _set_fangs(arm, spread=0.0, pitch=0.0):
    """Mandibles. `spread` is + flung apart / - crossed shut; `pitch` + down."""
    for tag in ("L", "R"):
        set_rot(arm.pose.bones[f"{tag}_fang"],
                ((0, 0, 1), spread * sign(tag)), ((1, 0, 0), pitch))


# The barrel's rest axis, normalised: it runs forward and slightly up, so
# recoil has to slide back along THAT, not along -Y.
_BARREL_AXIS = (0.0, 0.987, -0.159)


def _set_turret(arm, pitch, yaw=0.0, barrel=0.0, recoil=0.0, flare=1.0):
    """The dorsal cannon. `pitch`/`barrel` are + nose DOWN (so TURRET_STOW is
    positive and TURRET_DEPLOY negative), `yaw` swings it left/right, `recoil`
    slides the barrel back along its own axis, `flare` is the muzzle blast."""
    set_rot(arm.pose.bones["turret"], ((1, 0, 0), pitch), ((0, 0, 1), yaw))
    set_rot(arm.pose.bones["barrel"], ((1, 0, 0), barrel))
    set_loc(arm.pose.bones["barrel"], tuple(a * recoil for a in _BARREL_AXIS))
    arm.pose.bones["barrel"].scale = (flare, flare, flare)


def _set_leg(arm, tag, leg, up=0.0, yaw=0.0, fold=0.0, foot=0.0):
    """One leg. `up` raises the knee, `yaw` reaches it forward, `fold` swings
    the shin OUTWARD (which also lifts the tip -- see ROOT_LEGS for the
    measured table; negative pulls the foot in under the body), `foot`
    pitches the claw, negative planting it further out."""
    s = sign(tag)
    set_rot(arm.pose.bones[f"{tag}_{leg}_upper"],
            ((0, 0, 1), yaw * s), ((0, 1, 0), -up * s))
    set_rot(arm.pose.bones[f"{tag}_{leg}_lower"], ((0, 1, 0), -fold * s))
    set_rot(arm.pose.bones[f"{tag}_{leg}_foot"], ((0, 1, 0), foot * s))


def _set_legs(arm, up=0.0, yaw=0.0, fold=0.0, foot=0.0):
    for tag, leg in ALL_LEGS:
        _set_leg(arm, tag, leg, up, yaw, fold, foot)


# --- the two neutral poses ---------------------------------------------------
#
# Both forms' clips open (and close) here, and `Root` runs from one to the
# other. Keeping them as functions is what guarantees the transition's end
# pose and the anchored idle's start pose are bit-identical.

def _walk_neutral(arm, lift=WALK_LIFT):
    """Standing on all six, cannon stowed nose-down over the head."""
    rig_lib.rest(arm)
    _set_body(arm, lift=lift)
    _set_fangs(arm, spread=6.0)
    _set_turret(arm, TURRET_STOW)
    _set_legs(arm)


def _anchored(arm, lift_bias=0.0, pitch_bias=0.0, shove=0.0,
              turret_pitch=TURRET_DEPLOY, turret_yaw=0.0, barrel=0.0,
              recoil=0.0, flare=1.0, leg_bias=0.0, fang_spread=2.0):
    """Legs splayed and planted, thorax sunk, cannon locked nose-up.

    `lift_bias` / `pitch_bias` / `shove` / `leg_bias` are the small deviations
    the anchored clips breathe and recoil through; all default to zero, so
    calling this bare gives the exact pose `Root` must finish on."""
    rig_lib.rest(arm)
    _set_body(arm, pitch=ROOT_PITCH + pitch_bias, shove=shove,
              lift=ROOT_LIFT + lift_bias, head=-6.0, flare=flare)
    _set_fangs(arm, spread=fang_spread, pitch=8.0)
    _set_turret(arm, turret_pitch, yaw=turret_yaw, barrel=barrel,
                recoil=recoil, flare=flare)
    for leg, (up, yaw, fold, foot) in ROOT_LEGS.items():
        for tag in ("L", "R"):
            _set_leg(arm, tag, leg, up=up + leg_bias, yaw=yaw,
                     fold=fold + leg_bias * 0.6, foot=foot)


# --- Idle (walking form) -----------------------------------------------------

def build_idle(arm, length=60):
    """A slow, heavy breath -- 2.5s a loop, the same as the lancer's, because
    this is the other armoured unit. The carapace rises and settles, the
    stowed cannon rocks a quarter-beat behind it, and the mandibles work."""
    act = rig_lib.new_action(arm, "Idle")
    for f in range(0, length + 1, 4):
        t = f / length
        pulse = math.sin(t * math.tau)
        lag = math.sin(t * math.tau - 0.8) + math.sin(0.8)      # the gun lags the body
        chew = math.sin(t * math.tau * 2.0)     # mandibles, twice a breath

        _walk_neutral(arm, lift=WALK_LIFT + 0.022 * pulse)
        _set_body(arm, pitch=-1.4 * pulse, lift=WALK_LIFT + 0.022 * pulse,
                  head=2.6 * pulse)
        _set_fangs(arm, spread=6.0 + 5.0 * chew, pitch=3.0 * chew)
        _set_turret(arm, TURRET_STOW - 3.0 * lag, yaw=2.5 * lag)
        for tag, leg in ALL_LEGS:
            _set_leg(arm, tag, leg, up=-2.4 * pulse, fold=3.0 * pulse)

        rig_lib.key(arm, f, ALL_KEYED, loc_bones=MOVED, scale_bones=FLARED)

    rig_lib.set_range(act, 0, length)
    rig_lib.smooth_action(act)
    return act


# --- Run (walking form) ------------------------------------------------------

def build_run(arm, length=20):
    """A LUMBER. speed 2.0 is the slowest in the roster (mite 3.5, lancer 3.2),
    so this is the longest gait cycle -- 0.83s against the lancer's 0.67 and
    the mite's 0.50 -- with a deep two-per-cycle heave as each tripod takes the
    weight. The stowed cannon pitches against the heave so the top of the
    silhouette is never still."""
    act = rig_lib.new_action(arm, "Run")
    for f in range(0, length + 1):
        t = f / length
        _walk_neutral(arm)
        for tag, leg in TRIPOD_A:
            rig_lib.leg_gait(arm, tag, leg, t, reach=25.0, lift=30.0, curl=24.0)
        for tag, leg in TRIPOD_B:
            rig_lib.leg_gait(arm, tag, leg, t + 0.5, reach=25.0, lift=30.0, curl=24.0)

        heave = math.sin(t * math.tau * 2.0)
        roll = math.sin(t * math.tau)
        _set_body(arm, pitch=-2.0 - 3.0 * heave,
                  # +0.014 of headroom over the standing lift: the gait's own
                  # leg swing already eats most of the 0.000 rest clearance.
                  lift=WALK_LIFT + 0.014 + 0.038 * heave,
                  # Feet reach x = +-0.66, so roll is the biggest single threat
                  # to ground clearance: keep it small and pay in lift.
                  roll=1.6 * roll, head=3.0 + 5.0 * heave)
        _set_fangs(arm, spread=9.0 + 4.0 * heave, pitch=2.0 * heave)
        _set_turret(arm, TURRET_STOW + 5.0 * heave, yaw=-3.5 * roll)

        rig_lib.key(arm, f, ALL_KEYED, loc_bones=MOVED, scale_bones=FLARED)

    rig_lib.set_range(act, 0, length)
    rig_lib.smooth_action(act)
    return act


# --- Attack (walking form: the mandible bite) --------------------------------
#
# Range 0.6 -- this is the melee form, and the weapon is the pair of mandibles
# slung under the face. The beats are the readability calibration the mite
# rework set: rear back FAR, then commit forward FAR, because at thumbnail
# size a swing that stays inside the silhouette is invisible.
#
#   REAR    0.54s. The creature rocks back over its rear legs and stands up:
#           thorax 29 deg nose-UP, hauled 0.40 back, lifted 0.225, front legs
#           62 deg off the floor, mandibles flung 48 deg apart. The cannon
#           LEVELS as the body tilts under it (24 -> 2), which is both what a
#           stabilised mount would do and what keeps the tallest part of the
#           silhouette high while the body rotates away from it. Held a frame.
#   POUNCE  3 frames. The whole body is thrown 0.63 forward and slams 21 deg
#           nose-DOWN, front legs stabbing ahead.
#   BITE    1 frame. Mandibles snap shut CROSSED (-16 deg) and the head flares
#           to 1.10x -- the contact.
#   SETTLE  0.5s that lags: dug in, then a hard six-legged SLAM at f24, a
#           rebound, and home.
#
# Measured on the deformed mesh, for the calibration the mite rework set:
#   * the silhouette rears to 1.832 at f13 -- 1.26x the 1.452 standing height
#     (mite 1.30x, spitter 1.54x);
#   * the body centre travels +0.386 back to -0.562 forward, i.e. 0.947, or
#     68% of this creature's own 1.389 body length (mite ~60%, lancer 73%);
#   * nothing dips below the floor: the lowest point of the whole clip is
#     +0.012, and the pounce legitimately leaves the ground (floor +0.220).
#
# Columns, world-space:
#   pit    thorax pitch, + nose DOWN
#   shove  thorax translation along Y, + BACKWARD
#   lift   thorax translation along Z. Rising is free; sinking clips.
#   hd     head pitch, + nose down (compounds onto the thorax)
#   fsp    mandible spread, + apart, - crossed shut;  fpt  mandible pitch
#   tur    cannon pitch, + nose down. It is dead weight in this form, so it
#          just rides the body and clatters.
#   fore   front-leg raise, + up -- also the ground-clearance lever, holding
#          the front feet up while the body dives onto them
#   yaw    all-leg fore/aft yaw, + reaches forward
#   flare  head scale, one frame, on contact
#
#  f0 ..... f13 = f14 ==> f16 = f17 .. f19 ... f24 ... f27 ... f30
#  neutral   REAR   hold  POUNCE  BITE  dug in  SLAM   rock   neutral
#  0.54s of windup       0.13s strike   0.54s of lagging recovery
#
# 30 frames at 24fps = 1.25s, inside hive.carapace's 1.5s cooldown. Rest is
# keyed TWICE (29 and 30): the glTF exporter's animation-size optimiser drops
# a final key it considers redundant.
ATTACK_BEATS = (
    # f,   pit,  shove,  lift,   hd,  fsp,  fpt,   tur, fore,  yaw, flare
    (0,    0.0,  0.000, 0.035,  0.0,  6.0,  0.0,  24.0,  0.0,  0.0, 1.00),
    (4,   -8.0,  0.120, 0.075, -7.0, 18.0, -4.0,  20.0, 16.0, 10.0, 1.00),
    (9,  -20.0,  0.270, 0.155,-16.0, 34.0,-10.0,  11.0, 42.0, 22.0, 1.00),
    (13, -29.0,  0.400, 0.225,-22.0, 48.0,-16.0,   2.0, 62.0, 33.0, 1.00),  # REAR
    (14, -29.0,  0.400, 0.225,-22.0, 48.0,-16.0,   2.0, 62.0, 33.0, 1.00),  # hold
    (16,  14.0, -0.450, 0.240,  8.0, 26.0,  4.0,  16.0, 30.0,-27.0, 1.00),  # POUNCE
    (17,  21.0, -0.630, 0.250, 15.0,-16.0, 10.0,  22.0, 34.0,-37.0, 1.10),  # BITE
    (19,  17.0, -0.500, 0.195, 11.0, 40.0,  6.0,  28.0, 24.0,-29.0, 1.00),  # dug in
    (21,  10.0, -0.330, 0.135,  6.0, 22.0,  2.0,  30.0, 16.0,-19.0, 1.00),
    (24,   0.0, -0.090, 0.038,  2.0, 12.0,  0.0,  27.0, 14.0, 12.0, 1.00),  # SLAM
    (26,  -8.0,  0.150, 0.095,-11.0, 14.0, -4.0,  20.0, 17.0, 19.0, 1.00),  # rebound
    (28,   2.0, -0.020, 0.046,  3.0,  8.0,  2.0,  25.0,  2.0, -3.0, 1.00),  # rock
    (29,   0.0,  0.000, 0.035,  0.0,  6.0,  0.0,  24.0,  0.0,  0.0, 1.00),  # home
    (30,   0.0,  0.000, 0.035,  0.0,  6.0,  0.0,  24.0,  0.0,  0.0, 1.00),  # hold
)
ATTACK_LENGTH = ATTACK_BEATS[-1][0]


def build_attack(arm):
    """Rear, pounce, bite, settle. One-shot, 1.25s inside a 1.5s cooldown."""
    act = rig_lib.new_action(arm, "Attack")

    for (f, pit, shove, lift, hd, fsp, fpt, tur, fore, yaw, flare) in ATTACK_BEATS:
        _walk_neutral(arm)
        _set_body(arm, pitch=pit, shove=shove, lift=lift, head=hd, flare=flare)
        _set_fangs(arm, spread=fsp, pitch=fpt)
        _set_turret(arm, tur)

        for tag in ("L", "R"):
            # Front legs rear right off the floor and stab forward on the
            # pounce; they are also what keeps the face out of the terrain
            # when the body slams nose-down onto them.
            _set_leg(arm, tag, "front", up=fore, yaw=yaw * 1.25,
                     fold=-fore * 0.35, foot=fore * 0.25)
            # Mids brace: a little raise, mostly yaw.
            _set_leg(arm, tag, "mid", up=fore * 0.22, yaw=yaw,
                     fold=-fore * 0.10)
            # Rears stay planted and drive the whole pounce, so they get
            # almost pure world-Z yaw: the foot sweeps along the floor instead
            # of being levered off it.
            _set_leg(arm, tag, "rear", up=fore * 0.08, yaw=yaw * 0.85,
                     fold=-fore * 0.05)

        rig_lib.key(arm, f, ALL_KEYED, loc_bones=MOVED, scale_bones=FLARED)

    rig_lib.set_range(act, 0, ATTACK_LENGTH, cyclic=False)

    # Timing carries as much of the read as the poses: AUTO_CLAMPED bezier
    # eases out of every key, which turns a 3-frame pounce into a drift.
    rig_lib.smooth_action(act)
    rig_lib.ease_out_of(act, 13)              # arrive at the rear without overshoot
    rig_lib.set_frame_interp(act, 14, 'LINEAR')   # leave the hold at full speed
    rig_lib.set_frame_interp(act, 16, 'LINEAR')   # ... and snap into the bite
    rig_lib.ease_out_of(act, 17)
    return act


# --- Root (the transition) ---------------------------------------------------
#
# The one clip that legitimately starts and ends on different poses: walking
# neutral in, anchored neutral out. Budgeted against hive.root's morph_time of
# 1.5s = 36 frames exactly, and staged as TWO separate events so a player
# reading a phone screen cannot miss it:
#
#   BRACE    f0-f6    the body rears and gathers, an anticipation beat
#   SPLAY    f6-f20   the six legs kick outward (feet x +-0.66 -> +-0.89) and
#                     the thorax drops 0.255, overshooting the anchored height
#                     by 0.033 and SLAMMING back onto it
#   LOCK     f20-f33  the cannon swings 50 deg from stowed to elevated,
#                     overshoots past the deployed angle, and locks
#   f34-f36            settle onto _anchored() exactly (keyed twice)
#
# Columns: `blend` is how far the pose has travelled from walking to anchored
# (0 = walking legs, 1 = the anchored splay), which is the leg/stance channel;
# `lift` and `pit` override the body so the drop can overshoot and rebound;
# `tur` is the cannon's own, deliberately LATER, channel.
#
# blend None means "the anchored pose EXACTLY" -- those frames call
# `_anchored()` and ignore the lift/pitch columns, so the end of this clip and
# the start of Rooted / RootedAttack cannot drift apart when the stance is
# retuned. Everything from f24 on is already parked, so only the gun moves.
ROOT_BEATS = (
    # f,  blend,   lift,   pit,   tur,  fsp
    (0,    0.00,  0.035,  0.0,  24.0,  6.0),
    (4,   -0.10,  0.105, -9.0,  30.0, 22.0),   # BRACE: rear up and gather
    (6,   -0.10,  0.100, -8.0,  30.0, 20.0),   # hold
    (12,   0.55, -0.055,  0.0,  27.0, 10.0),   # legs kicking out, body falling
    (18,   1.06, -0.288,  5.0,  24.0,  4.0),   # SLAM past the anchored height
    (21,   1.00, -0.221,  2.0,  23.0,  8.0),   # rebound
    (24,   None,   None, None,  16.0, None),   # planted; the gun starts to rise
    (29,   None,   None, None, -34.0, None),   # LOCK: swings past the stop
    (32,   None,   None, None, -22.0, None),   # settles back
    (34,   None,   None, None, -26.0, None),
    (35,   None,   None, None, -26.0, None),   # anchored neutral
    (36,   None,   None, None, -26.0, None),   # hold (the exporter drops one)
)
ROOT_LENGTH = ROOT_BEATS[-1][0]


def build_root(arm):
    """Walking form -> anchored turret, 36 frames = 1.5s = hive.root's
    morph_time. Ends on exactly `_anchored()`, which is where `Rooted` and
    `RootedAttack` both begin."""
    act = rig_lib.new_action(arm, "Root")

    for (f, blend, lift, pit, tur, fsp) in ROOT_BEATS:
        if blend is None:
            _anchored(arm, turret_pitch=tur)
        else:
            # The stance channel: interpolate every leg between standing and
            # splayed. `blend` is allowed outside 0..1 so the gather can go the
            # wrong way first and the plant can overshoot.
            _walk_neutral(arm)
            for leg, (up, yaw, fold, foot) in ROOT_LEGS.items():
                for tag in ("L", "R"):
                    _set_leg(arm, tag, leg, up=up * blend, yaw=yaw * blend,
                             fold=fold * blend, foot=foot * blend)
            _set_body(arm, pitch=pit, lift=lift, head=-6.0 * max(blend, 0.0))
            _set_fangs(arm, spread=fsp, pitch=8.0 * max(blend, 0.0))
            _set_turret(arm, tur)

        rig_lib.key(arm, f, ALL_KEYED, loc_bones=MOVED, scale_bones=FLARED)

    rig_lib.set_range(act, 0, ROOT_LENGTH, cyclic=False)
    rig_lib.smooth_action(act)
    rig_lib.set_frame_interp(act, 6, 'LINEAR')    # leave the brace and commit
    rig_lib.ease_out_of(act, 18)                  # the slam is a hard corner
    rig_lib.ease_out_of(act, 29)                  # so is the cannon's stop
    return act


# --- Rooted (anchored form idle) ---------------------------------------------

def build_rooted(arm, length=56):
    """Planted turret. Nothing walks: the legs only creak against the anchor,
    and the read is the cannon SCANNING -- a slow 24 deg sweep left and right
    with the barrel breathing against it, plus a charge pulse through the
    body twice a loop. 2.33s a loop, opening on `_anchored()` so it can cut
    straight out of `Root` with no pop."""
    act = rig_lib.new_action(arm, "Rooted")
    for f in range(0, length + 1, 4):
        t = f / length
        scan = math.sin(t * math.tau)           # one full sweep per loop
        charge = math.sin(t * math.tau * 2.0)   # the pulse, twice

        # The lift and the leg bias pull against each other on purpose: the
        # thorax swells 0.020 while the legs give 1.8 deg back, so the body
        # visibly breathes and the six planted feet still do not move.
        _anchored(arm,
                  lift_bias=0.020 * charge,
                  pitch_bias=-1.2 * charge,
                  turret_pitch=TURRET_DEPLOY - 4.0 * charge,
                  turret_yaw=24.0 * scan,
                  barrel=-2.5 * charge,
                  leg_bias=-1.8 * charge,
                  fang_spread=2.0 + 4.0 * charge)

        rig_lib.key(arm, f, ALL_KEYED, loc_bones=MOVED, scale_bones=FLARED)

    rig_lib.set_range(act, 0, length)
    rig_lib.smooth_action(act)
    return act


# --- RootedAttack (anchored form: the cannon shot) ---------------------------
#
# Range 4.0 and hits_air -- this is the ranged form, and it has to read as a
# SHOT, not a swing. Nothing travels: the creature is bolted down, so the
# whole motion is stored energy released backwards.
#
#   RACK     f0-f7   the cannon elevates a little further, the barrel slides
#                    0.05 FORWARD, and the body creeps forward on its mount
#   FIRE     f9      the barrel slams 0.30 BACK along its own axis (45% of its
#                    own length, telescoping into the receiver), the gun kicks
#                    20 deg up, the thorax is shoved 0.165 backward and punched
#                    up, and the muzzle flares to 1.22x -- all in one frame.
#                    The backward shove is the readable part: from the RTS
#                    camera a bolted-down unit can only sell a shot by moving
#                    ACROSS the screen, never by travelling into it.
#   RIDE     f10-f16 the recoil runs out through the legs
#   RESET    f17-f26 the barrel runs forward again and the gun re-lays,
#                    finishing on `_anchored()` exactly
#
# 26 frames at 24fps = 1.083s, inside the morphed cooldown of 1.2s.
ROOTED_ATTACK_BEATS = (
    # f,   tur,  recoil,  shove,   lift,  pit,  legs, flare
    (0,  -26.0,   0.000,  0.000,  0.000,  0.0,  0.0, 1.00),
    (5,  -30.0,  -0.045, -0.030, -0.006,  1.8, -0.6, 1.00),   # RACK, creeps forward
    (7,  -30.0,  -0.050, -0.034, -0.007,  2.0, -0.7, 1.00),   # hold
    (9,  -46.0,   0.300,  0.165,  0.026, -8.0, -2.5, 1.22),   # FIRE
    (11, -40.0,   0.230,  0.124,  0.020, -5.6, -2.0, 1.00),
    (14, -30.0,   0.120,  0.055,  0.008, -2.0, -0.8, 1.00),   # riding it out
    (17, -20.0,   0.030, -0.022, -0.010,  1.8,  1.0, 1.00),   # settles low
    (21, -28.0,   0.006,  0.004,  0.003, -0.5, -0.2, 1.00),   # re-lays
    (24, -26.0,   0.000,  0.000,  0.000,  0.0,  0.0, 1.00),
    (25, -26.0,   0.000,  0.000,  0.000,  0.0,  0.0, 1.00),
    (26, -26.0,   0.000,  0.000,  0.000,  0.0,  0.0, 1.00),   # hold
)
ROOTED_ATTACK_LENGTH = ROOTED_ATTACK_BEATS[-1][0]


def build_rooted_attack(arm):
    """The anchored cannon shot. One-shot, 1.083s inside the morphed 1.2s
    cooldown; opens and closes on `_anchored()`."""
    act = rig_lib.new_action(arm, "RootedAttack")

    for (f, tur, recoil, shove, lift, pit, legs, flare) in ROOTED_ATTACK_BEATS:
        _anchored(arm, lift_bias=lift, pitch_bias=pit, shove=shove,
                  turret_pitch=tur, recoil=recoil, flare=flare, leg_bias=legs)
        rig_lib.key(arm, f, ALL_KEYED, loc_bones=MOVED, scale_bones=FLARED)

    rig_lib.set_range(act, 0, ROOTED_ATTACK_LENGTH, cyclic=False)
    rig_lib.smooth_action(act)
    rig_lib.set_frame_interp(act, 7, 'LINEAR')   # leave the rack instantly
    rig_lib.ease_out_of(act, 9)                  # the shot is a hard corner
    return act


# --- assembly ----------------------------------------------------------------

def build_all(arm, spec=None):
    rig_lib.enter_pose_mode(arm)
    actions = [
        build_idle(arm),
        build_run(arm),
        build_attack(arm),
        build_root(arm),
        build_rooted(arm),
        build_rooted_attack(arm),
    ]
    return rig_lib.finalize(arm, actions, scene_end=60)
