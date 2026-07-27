"""Idle / Fly / Attack actions for the Hive Laser Moth (units.LASER_MOTH).

Loaded by rig_unit.py via the spec's `anim_module`; safe to re-run on an
existing rig (each build_* call replaces its action). Poses are written as
world-axis rotations per bone and baked to quaternions, so the maths reads the
way the motion looks: `(1, 0, 0)` pitches, `(0, 1, 0)` raises a wing,
`(0, 0, 1)` yaws / sweeps one fore-and-aft.

Sign note, because this rig has bones pointing BOTH ways along Y: a positive
world-X rotation swings a bone's tail downward. `thorax` / `head` / `emitter`
point -Y, so +deg is nose DOWN for them; `abdomen` / `stinger` point +Y, so
+deg lifts the tail. For a wing extending along +X, a NEGATIVE world-Y
rotation raises it, hence the `-elev * side` everywhere below (the same
convention rig_lib.leg_gait uses to lift a leg).

THIS UNIT IS A FLYER AND THE SIM DOES NOT KNOW IT. There is no aerial flag on
a catalog unit; the moth pathfinds on the ground grid like everything else.
The whole illusion is the asset: units.LASER_MOTH declares `hover=0.55`, so
the mesh is authored 0.55 above its own origin while the origin stays on the
terrain, and these three clips have to carry the rest of it. Two rules follow,
and they are the reason this module looks nothing like the walkers':

  * THE WINGS NEVER STOP. Every clip beats them, including the "still" one and
    including the frame the laser fires. A flyer that holds a pose is a prop.
  * THE BODY NEVER PARKS. Idle bobs, sways, rolls and drifts; nothing here is
    ever exactly at rest for more than the single frame a clip starts on.

Wingbeat rate is a deliberate lie. A real bee is ~200 Hz, which at 24 fps is
not a wingbeat but noise, so the beat is stylised down to 3 Hz idling and 4 Hz
flying — slow enough to read as flapping at thumbnail size on a phone, fast
enough that it never reads as gliding. The periods are chosen to divide their
clip lengths exactly (8 into 48, 6 into 12, 5.4 into 27) so every loop is
seamless and the Attack starts and ends dead on the rest pose.

Animation direction (design.md "Art & Audio Direction"): units are read at
thumbnail size, so these favour few, high-contrast poses over smooth realism.
Where the lancer is deliberate and the mite frantic, the moth is TWITCHY: it
never holds still, and its attack is the biggest single silhouette change of
any unit here — wings snapped from near-vertical to below horizontal in three
frames while the whole body dives forward.
"""

import math

import rig_lib
from rig_lib import set_rot, set_loc, sign

FPS = rig_lib.FPS
TAU = math.tau

SPINE = ("thorax", "head", "abdomen", "stinger", "emitter")
WINGS = ("L_wing", "R_wing", "L_wing_tip", "R_wing_tip")
ANTENNAE = ("L_antenna", "R_antenna")
ALL_KEYED = SPINE + WINGS + ANTENNAE
MOVED = ("thorax",)        # the only translated bone: the sim owns position
FLARED = ("emitter",)      # scaled, for the discharge flare on the shot

## Rest elevation of a wing above horizontal, measured off the mesh. Every
## `elev` below is an offset FROM this, so elev = -42 lays a wing flat.
WING_REST_ELEV = 42.0


# --- pose helpers ------------------------------------------------------------

def _set_wings(arm, elev, sweep, tip_elev, tip_sweep=0.0):
    """`elev` is + wing UP, `sweep` is + swept FORWARD; tip values compound."""
    for tag in ("L", "R"):
        s = sign(tag)
        set_rot(arm.pose.bones[f"{tag}_wing"],
                ((0, 1, 0), -elev * s), ((0, 0, 1), -sweep * s))
        set_rot(arm.pose.bones[f"{tag}_wing_tip"],
                ((0, 1, 0), -tip_elev * s), ((0, 0, 1), -tip_sweep * s))


def _set_antennae(arm, pitch, spread):
    """`pitch` is + swept forward and DOWN, - laid back; `spread` is + apart."""
    for tag in ("L", "R"):
        s = sign(tag)
        set_rot(arm.pose.bones[f"{tag}_antenna"],
                ((1, 0, 0), pitch), ((0, 0, 1), spread * s))


def _set_body(arm, pitch=0.0, roll=0.0, yaw=0.0, head=0.0, abd=0.0, sting=0.0,
              emit=0.0, surge=0.0, lift=0.0, drift=0.0, flare=1.0):
    """Body pose from world-space quantities.

    `pitch` / `head` / `emit` are + nose DOWN; `abd` / `sting` are + tail UP;
    `surge` is + BACKWARD (the creature faces -Y); `lift` is + up and is the
    hover clearance modifier, so it must never approach -0.55; `drift` is a
    sideways slide. `flare` scales the emitter pod.
    """
    set_rot(arm.pose.bones["thorax"],
            ((1, 0, 0), pitch), ((0, 1, 0), roll), ((0, 0, 1), yaw))
    set_rot(arm.pose.bones["head"], ((1, 0, 0), head))
    set_rot(arm.pose.bones["abdomen"], ((1, 0, 0), abd))
    set_rot(arm.pose.bones["stinger"], ((1, 0, 0), sting))
    set_rot(arm.pose.bones["emitter"], ((1, 0, 0), emit))
    set_loc(arm.pose.bones["thorax"], (drift, surge, lift))
    arm.pose.bones["emitter"].scale = (flare, flare, flare)


# --- Idle --------------------------------------------------------------------
#
# Station-keeping, not standing still: 48 frames (2.0s) of hover. The wings
# beat six times over the loop (8 frames, 3.0 Hz) and HARD — a 64 deg sweep,
# because hovering is the expensive thing an insect does, and a smaller one is
# simply not visible at thumbnail size — while the body breathes twice and
# yaws/drifts once, so no two frames of the loop share a silhouette and the
# periods never line up into an obvious pulse.

IDLE_LENGTH = 48
IDLE_WING_PERIOD = 8.0      # 3.0 Hz at 24 fps
IDLE_WING_AMP = 32.0


def build_idle(arm, length=IDLE_LENGTH):
    act = rig_lib.new_action(arm, "Idle")
    rig_lib.rest(arm)
    for f in range(0, length + 1):
        p = f / IDLE_WING_PERIOD
        beat = math.sin(TAU * p)
        lag = math.sin(TAU * (p - 0.125))         # the membrane trails the spar
        swing = math.sin(TAU * (p - 0.25))        # figure-eight, a quarter behind
        breath = math.sin(TAU * f / 24.0)         # two per loop
        drift_w = math.sin(TAU * f / length)      # one per loop

        _set_wings(arm,
                   elev=IDLE_WING_AMP * beat + 3.0 * breath,
                   sweep=8.0 * swing + 4.0 * breath,
                   tip_elev=16.0 * lag,
                   tip_sweep=5.0 * math.sin(TAU * (p - 0.375)))
        _set_body(arm,
                  pitch=-3.0 + 4.0 * breath,
                  roll=2.5 * drift_w,
                  yaw=4.0 * math.sin(TAU * f / length - 0.6),
                  head=-3.0 * breath,
                  abd=5.0 + 5.0 * math.sin(TAU * f / 24.0 - 1.0),
                  sting=4.0 + 6.0 * math.sin(TAU * f / 24.0 - 1.6),
                  emit=-2.0 - 3.0 * breath,
                  surge=0.010 * math.sin(TAU * f / length - 1.2),
                  # Hover clearance is 0.55; the bob rides on top of it, so
                  # the mesh never comes near the floor in this clip.
                  lift=0.040 * breath + 0.022 * beat,
                  drift=0.018 * drift_w)
        _set_antennae(arm,
                      pitch=-4.0 + 5.0 * math.sin(TAU * f / 24.0 - 0.5),
                      spread=6.0 + 4.0 * breath)
        rig_lib.key(arm, f, ALL_KEYED, loc_bones=MOVED, scale_bones=FLARED)

    rig_lib.set_range(act, 0, length)
    rig_lib.smooth_action(act)
    return act


# --- Fly ---------------------------------------------------------------------
#
# The movement clip (the catalog wires it as `move`). Half a second per loop,
# two beats in it at 4.0 Hz — a third faster than Idle and with a quarter more
# amplitude, which is the "beating harder" read. The body commits: 20 deg
# nose-DOWN into the direction of travel with the abdomen streaming behind it
# and the antennae laid flat, so a moving moth and a hovering moth are
# different silhouettes even frozen.

FLY_LENGTH = 12
FLY_WING_PERIOD = 6.0       # 4.0 Hz at 24 fps
FLY_WING_AMP = 40.0


def build_fly(arm, length=FLY_LENGTH):
    act = rig_lib.new_action(arm, "Fly")
    rig_lib.rest(arm)
    for f in range(0, length + 1):
        p = f / FLY_WING_PERIOD
        beat = math.sin(TAU * p)
        lag = math.sin(TAU * (p - 0.125))
        weave = math.sin(TAU * f / length)

        _set_wings(arm,
                   # Stroke plane tilted down and swept back: the wings are
                   # pushing the body forward, not just holding it up.
                   elev=FLY_WING_AMP * beat - 6.0,
                   sweep=14.0 * math.sin(TAU * (p - 0.25)) - 6.0,
                   tip_elev=18.0 * lag,
                   tip_sweep=8.0 * math.sin(TAU * (p - 0.375)))
        _set_body(arm,
                  pitch=20.0 + 3.0 * beat,
                  roll=3.5 * weave,
                  yaw=2.5 * math.sin(TAU * f / length - 0.8),
                  head=-5.0,                       # eyes stay on the horizon
                  abd=-9.0 + 4.0 * math.sin(TAU * (p - 0.2)),
                  sting=-6.0 + 5.0 * math.sin(TAU * (p - 0.35)),
                  emit=-6.0,
                  surge=-0.022,                    # leaning into the travel
                  lift=-0.028 + 0.040 * beat,      # bobs once per wingbeat
                  drift=0.012 * weave)
        _set_antennae(arm, pitch=-12.0 + 3.0 * beat, spread=3.0)
        rig_lib.key(arm, f, ALL_KEYED, loc_bones=MOVED, scale_bones=FLARED)

    rig_lib.set_range(act, 0, length)
    rig_lib.smooth_action(act)
    return act


# --- Attack ------------------------------------------------------------------
#
# The laser shot, and the whole thing has to be told by the BODY: there is no
# beam VFX, so if the pose does not sell it nothing does. Built to the same
# brief the mite's rework set — "we can't really see the mite's attack at all;
# zerglings pull way back and then lunge forward for exactly this reason" —
# and pitched at the finished units' measured amplitudes.
#
#   CHARGE   0.46s. The moth hauls BACKWARD and UP over its own hover, rears
#            38 deg nose-up, curls the abdomen up under itself, lays the
#            antennae flat back, cranes the emitter pod at the sky, and beats
#            higher every frame (beat centre climbing to +22 deg).
#   HOLD     f11 -> f12, dead still except the wings, which arrive at f12 with
#            the beat at its TOP: both wings 90 deg up, vertical over the back.
#            That one frame is the anticipation the whole clip hangs on.
#   FIRE     3 frames. The body is thrown 0.72 forward and pitches from 38 deg
#            nose-up to 34 deg nose-DOWN, the emitter swings from pointing at
#            the sky to dead ahead and flares to 1.22x on the shot frame, the
#            antennae fling forward — and the wingbeat, whose period was
#            picked so this lands on a down-stroke, slams from +90 deg to -26
#            deg (well below horizontal) in the same three frames.
#   RECOIL   f16 -> f18. Punched backward and upward off the shot, wings flung
#            back up, head snapping away.
#   SETTLE   0.37s of overshoot and rock back to neutral.
#
# Measured on the deformed mesh, against a body 0.82 long (BODY shell), a
# model 0.90 long overall and a 1.40 silhouette at rest:
#   * the silhouette rears to 1.73 on the hold frame and collapses to 1.00
#     three frames later — 1.24x rest against 1.73:1 between the two poses
#     that matter (mite 1.30x, carapace 1.26x);
#   * the model's centre travels +0.37 back at the coil to -0.42 forward at
#     the shot: 0.79, 88% of its own length (mite ~60%, lancer 73%,
#     carapace 68%) — the moth darts, so it is the biggest of the five;
#   * the wing tips sweep 0.76 vertically, 116 deg of arc, between f12 and
#     f15: the biggest single silhouette change of any clip in the project.
# Hover clearance never collapses: the lowest deformed vertex sits at 0.39 on
# the dive frame and 0.79 at the top of the coil, against 0.55 at rest, so it
# still reads as flying at the most extreme pose in the set.
#
# Columns, all world-space unless noted:
#   pitch  thorax pitch, + nose DOWN     head   local head pitch, + nose down
#   abd    abdomen pitch, + tail UP      sting  the same for the stinger
#   emit   emitter pod pitch, + muzzle down (rest is 36 deg above horizontal)
#   surge  thorax translation along Y, + is BACKWARD
#   lift   thorax translation along Z, on top of the 0.55 hover
#   ant    antenna pitch, + flung forward, - laid back
#   wmean  wingbeat centre, + higher    wamp  wingbeat amplitude, degrees
#   wswp   wing sweep centre, + forward  flare  emitter scale (the discharge)
#
#  f0 ...... f11 = f12 ==> f14 => f15 => f16 ... f18 ... f21 .. f24 .. f27
#  neutral    COIL  hold  snap  FIRE  recoil  flung back  sag   rock  neutral
#  0.46s of windup       0.13s of shot        0.50s of recovery
#
# The clip starts and ends on the rest pose with the body untranslated -- the
# sim owns position, so there is no root motion. Rest is keyed TWICE, on 26 and
# 27: the glTF exporter's animation-size optimiser drops a final key it
# considers redundant, and the duplicate guarantees the clip Godot plays still
# ends dead on rest. 27 frames at 24fps = 1.125s, inside hive.laser_moth's
# 1.2s cooldown.
ATTACK_BEATS = (
    # f, pitch,  head,   abd, sting,  emit,  surge,   lift,   ant, wmean, wamp,  wswp, flare
    (0,    0.0,   0.0,   0.0,   0.0,   0.0,  0.000,  0.000,   0.0,   0.0, 22.0,   0.0, 1.00),
    (3,  -11.0,  -7.0,  12.0,  15.0, -10.0,  0.090,  0.060, -14.0,   5.0, 26.0,   6.0, 1.00),
    (7,  -26.0, -16.0,  26.0,  33.0, -22.0,  0.220,  0.160, -28.0,  11.0, 27.0,  12.0, 1.00),
    (11, -38.0, -22.0,  38.0,  48.0, -32.0,  0.320,  0.240, -36.0,  22.0, 26.0,  18.0, 1.00),  # COIL
    (12, -38.0, -22.0,  38.0,  48.0, -32.0,  0.320,  0.240, -36.0,  22.0, 26.0,  18.0, 1.00),  # hold
    (14,  22.0,   8.0, -14.0, -20.0,  -8.0, -0.280,  0.030,  22.0, -14.0, 32.0, -18.0, 1.00),  # snap
    (15,  34.0,  14.0, -24.0, -32.0,   2.0, -0.400, -0.080,  40.0, -34.0, 34.0, -26.0, 1.22),  # FIRE
    (16,  26.0,  10.0, -18.0, -25.0,  -3.0, -0.300, -0.030,  30.0, -24.0, 32.0, -18.0, 1.08),
    (18, -12.0,  -6.0,  20.0,  26.0, -18.0,  0.200,  0.130, -18.0,  14.0, 30.0,  10.0, 1.00),  # flung back
    (21,  11.0,   5.0, -10.0, -13.0,  -2.0, -0.090, -0.040,  13.0,  -7.0, 26.0,  -7.0, 1.00),  # sag
    (24,  -5.0,  -3.0,   6.0,   8.0,  -7.0,  0.035,  0.035,  -6.0,   4.0, 24.0,   4.0, 1.00),  # rock
    (26,   0.0,   0.0,   0.0,   0.0,   0.0,  0.000,  0.000,   0.0,   0.0, 22.0,   0.0, 1.00),  # home
    (27,   0.0,   0.0,   0.0,   0.0,   0.0,  0.000,  0.000,   0.0,   0.0, 22.0,   0.0, 1.00),  # hold
)
ATTACK_LENGTH = ATTACK_BEATS[-1][0]
## 27 / 5.4 = exactly 5 beats, so the clip opens and closes with the wings on
## the rest angle -- and 15 / 5.4 lands the shot frame 0.97 of the way into a
## DOWN-stroke, which is why the power stroke and the laser coincide for free.
ATTACK_WING_PERIOD = 5.4
## Columns 9..11 of ATTACK_BEATS, sampled every frame instead of every beat:
## the wingbeat is faster than the body's key spacing, so it is driven from a
## linear interpolation of these rather than from the keys themselves.
_WING_COLS = (9, 10, 11)


def _wing_drive(f):
    """(mean, amplitude, sweep centre) on frame `f`, lerped between beats."""
    lo = ATTACK_BEATS[0]
    for hi in ATTACK_BEATS:
        if hi[0] >= f:
            span = hi[0] - lo[0]
            t = 1.0 if span <= 0 else (f - lo[0]) / span
            return tuple(lo[c] + (hi[c] - lo[c]) * t for c in _WING_COLS)
        lo = hi
    return tuple(lo[c] for c in _WING_COLS)


def build_attack(arm, length=ATTACK_LENGTH):
    """Charge, fire, recoil. One-shot; 27 frames at 24fps = 1.125s, inside
    hive.laser_moth's 1.2s cooldown."""
    act = rig_lib.new_action(arm, "Attack")
    rig_lib.rest(arm)

    # Wings on EVERY frame -- a 5.4-frame beat cannot be carried by the body's
    # key spacing, and the whole point is that it never pauses, not even on the
    # hold frame or the shot frame.
    for f in range(0, length + 1):
        p = f / ATTACK_WING_PERIOD
        mean, amp, swp = _wing_drive(f)
        # The lag terms are the only ones that are not zero at phase 0, so
        # they are windowed in and out over three frames. Without that the
        # clip would open and close a few degrees off the rest pose.
        w = min(1.0, f / 3.0, (length - f) / 3.0)
        _set_wings(arm,
                   elev=mean + amp * math.sin(TAU * p),
                   sweep=swp + w * 12.0 * math.sin(TAU * (p - 0.25)),
                   tip_elev=w * 0.5 * amp * math.sin(TAU * (p - 0.125)),
                   tip_sweep=w * 7.0 * math.sin(TAU * (p - 0.375)))
        rig_lib.key(arm, f, WINGS)

    for (f, pitch, head, abd, sting, emit,
         surge, lift, ant, _wmean, _wamp, _wswp, flare) in ATTACK_BEATS:
        _set_body(arm, pitch=pitch, head=head, abd=abd, sting=sting, emit=emit,
                  surge=surge, lift=lift, flare=flare)
        _set_antennae(arm, ant, 8.0 + 0.5 * abs(ant))
        rig_lib.key(arm, f, SPINE + ANTENNAE,
                    loc_bones=MOVED, scale_bones=FLARED)

    rig_lib.set_range(act, 0, length, cyclic=False)

    # Timing is the other half of the read. Default bezier eases out of every
    # key, which turns the shot into a drift. The coil arrives without
    # overshooting (vector handles on 11), holds dead still to 12, then leaves
    # 12 LINEAR so the dive travels at full speed from its very first frame;
    # 14 and 15 leave LINEAR too so the shot and the recoil are hard corners.
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
    actions = [build_idle(arm), build_fly(arm), build_attack(arm)]
    return rig_lib.finalize(arm, actions)
