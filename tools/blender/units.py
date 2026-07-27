"""Unit specs for the Blender -> glTF pipeline: one entry per modelled unit.

Adding a unit is *data*, not a new copy of the rig script. Declare it here and
it becomes buildable and exportable:

    blender --background --python tools/blender/rig_unit.py -- <name> [--force]
    make rig UNIT=<name>      # same thing, then re-exports
    make models               # exports every unit that has a .blend

Deliberately importable by plain `python3` (no `bpy`): the Makefile queries it
for paths, and the CLI at the bottom is that query interface.

A spec carries the whole body plan — where the OBJ lives, how it is oriented
and scaled, the bone layout, and which module builds its animations. Body
plans genuinely differ between creatures (leg count, whether the legs hang off
the thorax or the abdomen, what the face articulates), so the layout is per
unit; only the *construction* of a leg chain and the pose maths are shared, in
rig_lib.py.

Conventions every spec must respect (see CLAUDE.md "Asset pipeline"):
  * Blender Z-up, the creature faces -Y, so glTF lands it facing -Z (Godot's
    forward).
  * Scaled to the catalog `view.height` of `catalog_key` so the view layer can
    instance the model at scale 1, origin at the feet.
  * Bones are <side>_<part> with sides L/R and X mirrored; `root` sits at the
    origin and carries no skin weight.
"""

from dataclasses import dataclass, field
import os
import sys

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

Vec = tuple  # (x, y, z) in metres, Blender axes


@dataclass(frozen=True)
class Bone:
    """A single, non-mirrored bone (spine segments, root)."""
    name: str
    head: Vec
    tail: Vec
    parent: str = ""
    connect: bool = False


@dataclass(frozen=True)
class Pair:
    """A bone mirrored across X; built as L_<name> and R_<name>.

    Coordinates are written for the RIGHT side (+X) and negated for the left.
    `parent` may contain "{s}", which is replaced with this bone's own side
    tag -- that is how a two-segment wing hangs its tip off the matching
    side's root ("{s}_wing") instead of off one shared bone.
    """
    name: str
    head: Vec
    tail: Vec
    parent: str = ""


@dataclass(frozen=True)
class Leg:
    """One mirrored leg: upper (hip->knee), lower (knee->ankle), foot (->tip).

    Coordinates are the right side; X is negated for the left. `ankle_t` is
    where the ankle falls along the knee->tip run and `ankle_bow` how far it
    bows outward, which is what gives the leg its insect kink.
    """
    name: str
    hip: Vec
    knee: Vec
    foot: Vec
    parent: str
    ankle_t: float = 0.70
    ankle_bow: float = 0.03


@dataclass(frozen=True)
class Unit:
    name: str
    obj: str                     # repo-relative vendor OBJ
    blend: str                   # repo-relative .blend (the hand-edit surface)
    glb: str                     # repo-relative export target
    catalog_key: str             # the data/catalog entry this model serves
    target_height: float         # == that entry's view.height
    mesh_name: str
    arm_name: str
    root: Bone
    spine: tuple                 # Bone, in parent-before-child order
    legs: tuple = ()             # Leg
    pairs: tuple = ()            # Pair (mandibles, wings, spikes...)
    anim_module: str = ""        # module with build_all(arm, spec)
    # Ground clearance, metres. 0 = feet on the floor (every walker). A FLYER
    # sets it: the mesh is authored this far above its own origin, so Godot
    # still places the model on the terrain and it visually floats. The sim
    # has no flight — see LASER_MOTH.
    hover: float = 0.0
    # Applied in order to the imported OBJ, then baked, before scaling. The
    # Tripo exports are Y-up with the head at +X, which these two undo.
    import_rotations: tuple = ((90.0, 0.0, 0.0), (0.0, 0.0, -90.0))

    # --- absolute paths (the scripts run from wherever Blender was launched) --
    @property
    def obj_path(self) -> str:
        return os.path.join(REPO, self.obj)

    @property
    def blend_path(self) -> str:
        return os.path.join(REPO, self.blend)

    @property
    def glb_path(self) -> str:
        return os.path.join(REPO, self.glb)

    def leg_names(self) -> list:
        return [leg.name for leg in self.legs]


# --- the roster --------------------------------------------------------------
# Hexapod, hive.mite (height 0.9). Leg geometry was measured off the source
# mesh: foot tips are the mesh's own ground-contact clusters, hips and knees
# sit inside the leg volume.
MITE = Unit(
    name="mite",
    obj="assets/models/Hive/mite/mechanical+swarmer+3d+model.obj",
    blend="assets/source/hive_mite.blend",
    glb="assets/models/Hive/hive_mite.glb",
    catalog_key="hive.mite",
    target_height=0.9,
    mesh_name="hive_mite_body",
    arm_name="hive_mite_rig",
    root=Bone("root", (0, 0, 0), (0, -0.18, 0)),
    spine=(
        Bone("abdomen", (0, 0.42, 0.55), (0, 0.10, 0.58), parent="root"),
        Bone("thorax", (0, 0.10, 0.58), (0, -0.20, 0.58), parent="abdomen", connect=True),
        Bone("head", (0, -0.20, 0.58), (0, -0.44, 0.50), parent="thorax", connect=True),
    ),
    pairs=(
        # The only articulated bit of the face; Attack opens and snaps them.
        Pair("mandible", (0.07, -0.38, 0.44), (0.13, -0.52, 0.36), parent="head"),
    ),
    legs=(
        Leg("front", (0.16, -0.30, 0.47), (0.30, -0.42, 0.50), (0.298, -0.363, 0.059), "thorax"),
        Leg("mid", (0.17, 0.02, 0.47), (0.30, 0.06, 0.46), (0.287, 0.071, 0.193), "thorax"),
        Leg("rear", (0.17, 0.28, 0.47), (0.33, 0.36, 0.44), (0.359, 0.431, 0.000), "abdomen"),
    ),
    anim_module="anim_mite",
)

# Hexapod spider, hive.spitter (height 1.2). Despite the vendor's "spider"
# name the mesh has three leg pairs, not four, so the shared tripod gait
# applies unchanged. Unlike the mite the body plan is a true spider's: every
# leg hangs off the cephalothorax (`thorax`), and the abdomen is a separate
# sac cantilevered off the BACK of it rather than a spine segment the legs
# ride on. That is what lets Attack swing and swell the venom sac hard
# without dragging six feet through the floor.
#
# This vendor OBJ needs only the Y-up->Z-up flip: it already has the head at
# -Z (which becomes -Y) and its mirror plane on X, where the mite's needed a
# further quarter turn. Measured off the mesh: foot tips are its own
# ground-contact clusters, knees the outer high point of each leg's volume.
SPITTER = Unit(
    name="spitter",
    obj="assets/models/Hive/spitter/mechanical+spider+3d+model.obj",
    blend="assets/source/hive_spitter.blend",
    glb="assets/models/Hive/hive_spitter.glb",
    catalog_key="hive.spitter",
    target_height=1.2,
    mesh_name="hive_spitter_body",
    arm_name="hive_spitter_rig",
    root=Bone("root", (0, 0, 0), (0, -0.24, 0)),
    spine=(
        # The legs' carrier, and the bone Attack translates: shoving this is
        # what makes the whole creature recoil.
        Bone("thorax", (0, 0.20, 0.84), (0, -0.26, 0.80), parent="root"),
        # Venom sac. Hangs off the thorax HEAD pointing aft, so raising it
        # rears the sac up over the back without touching a single leg.
        Bone("abdomen", (0, 0.20, 0.84), (0, 0.74, 0.92), parent="thorax"),
        Bone("neck", (0, -0.26, 0.80), (0, -0.46, 0.66), parent="thorax", connect=True),
        Bone("head", (0, -0.46, 0.66), (0, -0.80, 0.38), parent="neck", connect=True),
    ),
    pairs=(
        # Chelicerae. Clamped shut while the spit charges, flung wide as it
        # leaves -- the close-up half of the "something was launched" read.
        Pair("fang", (0.09, -0.66, 0.44), (0.15, -0.84, 0.25), parent="head"),
    ),
    legs=(
        Leg("front", (0.22, -0.44, 0.60), (0.54, -0.58, 0.66), (0.775, -0.748, 0.030), "thorax"),
        Leg("mid", (0.24, -0.24, 0.66), (0.62, -0.25, 0.72), (0.818, -0.150, 0.030), "thorax"),
        Leg("rear", (0.24, 0.26, 0.74), (0.56, 0.33, 0.86), (0.782, 0.520, 0.030), "thorax"),
    ),
    anim_module="anim_spitter",
    import_rotations=((90.0, 0.0, 0.0),),
)

# Hexapod with a lance, hive.lancer (height 1.6 -- the tallest unit so far).
# The vendor "sci-fi creature" is NOT the mite/spitter layout, so it was
# measured off the mesh rather than assumed. The OBJ falls into nine separate
# shells, which hand the body plan over directly:
#   * one 377-vert body -- a domed head/carapace rising to z=1.6 at the front,
#     a narrow waist, and a tail bulb arching up and back to y=+0.86;
#   * three mirrored leg pairs (~97 verts each) at y = -0.47 / +0.02 / +0.51,
#     so the shared tripod gait applies;
#   * a mirrored pair of 40-vert TUSKS slung under the head dome, running from
#     (0.21, -0.58, 1.08) down and forward to a point at (0.22, -0.87, 0.77),
#     i.e. 46 deg below horizontal at rest.
# Those tusks are the lance, and the whole Attack is built around swinging
# them: they are the only part of this creature with a weapon silhouette.
#
# Two spine details differ from the other two units and both exist to buy
# ground clearance, because every foot hangs off the spine:
#   * `thorax` pivots at y=+0.10, near the body's centre rather than at the
#     tail, so pitching the body levers the front feet only ~0.68 instead of
#     the whole body length;
#   * `hind` is a separate carrier for the rear legs and the tail, hanging off
#     the thorax PIVOT. Counter-rotating it holds the rear feet down while the
#     front rears -- which is what lets the coil be as deep as it is.
#
# Same Y-up -> Z-up flip as the spitter: this OBJ already has the head at -Z.
# Measured: foot tips are each leg shell's own lowest cluster (the rear pair
# rests 0.07 off the floor in the source mesh, which is the tightest ground
# margin of any unit), knees the outer high point of the leg volume.
LANCER = Unit(
    name="lancer",
    obj="assets/models/Hive/lancer/mechanical+sci-fi+creature+3d+model.obj",
    blend="assets/source/hive_lancer.blend",
    glb="assets/models/Hive/hive_lancer.glb",
    catalog_key="hive.lancer",
    target_height=1.6,
    mesh_name="hive_lancer_body",
    arm_name="hive_lancer_rig",
    root=Bone("root", (0, 0, 0), (0, -0.32, 0)),
    spine=(
        # Carries the front and mid legs; the only translated bone.
        Bone("thorax", (0, 0.10, 0.72), (0, -0.16, 0.86), parent="root"),
        # Rear-leg + tail carrier, hung off the thorax HEAD so it rotates
        # about the same pivot and can cancel the thorax's pitch.
        Bone("hind", (0, 0.10, 0.72), (0, 0.50, 0.64), parent="thorax"),
        Bone("tail", (0, 0.50, 0.64), (0, 0.76, 0.80), parent="hind", connect=True),
        Bone("tail_tip", (0, 0.76, 0.80), (0, 0.90, 0.96), parent="tail", connect=True),
        Bone("neck", (0, -0.16, 0.86), (0, -0.30, 1.08), parent="thorax", connect=True),
        Bone("head", (0, -0.30, 1.08), (0, -0.66, 1.06), parent="neck", connect=True),
    ),
    pairs=(
        # The lance. Spread wide and raised on the windup, snapped level and
        # forward on the thrust, flicked open again on the shock discharge.
        Pair("tusk", (0.20, -0.60, 1.06), (0.19, -0.87, 0.78), parent="head"),
    ),
    legs=(
        Leg("front", (0.15, -0.40, 0.50), (0.48, -0.50, 0.50), (0.500, -0.575, 0.022),
            "thorax", ankle_t=0.66, ankle_bow=0.04),
        Leg("mid", (0.16, 0.03, 0.48), (0.50, 0.03, 0.53), (0.605, 0.027, 0.022),
            "thorax", ankle_t=0.66, ankle_bow=0.04),
        Leg("rear", (0.15, 0.45, 0.52), (0.44, 0.50, 0.55), (0.446, 0.636, 0.072),
            "hind", ankle_t=0.66, ankle_bow=0.04),
    ),
    anim_module="anim_lancer",
    import_rotations=((90.0, 0.0, 0.0),),
)

# Hexapod siege spider, hive.carapace (height 1.4). The only unit with TWO
# forms -- hive.root morphs it between a walking melee tank and an anchored
# turret -- and the vendor mesh hands that reading over for free, because it
# is a low armoured spider carrying a DORSAL CANNON.
#
# The OBJ is a kit-bash: 63 disjoint shells, which give the body plan
# directly (all figures below are post-orient, post-scale Blender metres, so
# they are the numbers the spec itself is written in):
#   * a 107-vert carapace dome, y -0.51..+0.69, z 0.35..1.02 -- broad and
#     LOW, quite unlike the lancer's tall arch;
#   * a face slung under its front lip: a 60-vert block at y -0.63..-0.37,
#     z 0.41..0.74, a mirrored pair of 17-vert eyes at the very front
#     (y -0.70), and MANDIBLES below them at z 0.34..0.49 -- the melee weapon;
#   * the cannon on its back: a receiver block (y -0.09..+0.59, z 1.06..1.36)
#     and a 36-vert BARREL running forward from it to y -0.65 at z 1.24, on a
#     base ring that sits on the carapace top at z ~1.02;
#   * three mirrored leg pairs at y = -0.27 / +0.04 / +0.50, so the shared
#     tripod gait applies.
# The barrel is what makes the morph legible at thumbnail size: stowed 24 deg
# nose-down while walking, locked 26 deg nose-UP when rooted, which lifts its
# tip 0.48 in world terms and 0.77 relative to the body that drops underneath
# it. See anim_carapace.py.
#
# Same Y-up -> Z-up flip as the spitter and lancer (head already at -Z).
#
# Ground clearance is the tightest of every unit: the left middle foot sits at
# z = 0.000 exactly in the rest mesh (front 0.025, rear 0.025), so every clip
# carries a base thorax `lift` and the rooted crouch has to buy its 0.29 of
# sink by SPLAYING the feet outward rather than by dropping them. Measured:
# each leg is near full extension at rest (hip->tip 0.64 against a 0.66
# straightened reach), so folding is the only slack there is.
#
# This is also the first mesh whose islands defeat bone heat: 169 of its 1059
# vertices (the side pods, the leg spikes) are closed volumes enclosing no
# bone and came back with no weights at all, which would have left them
# hanging in the air. rig_lib.bind_orphans catches that -- a no-op on the
# other three units, which have none.
CARAPACE = Unit(
    name="carapace",
    obj="assets/models/Hive/carapace/robotic+spider+3d+model.obj",
    blend="assets/source/hive_carapace.blend",
    glb="assets/models/Hive/hive_carapace.glb",
    catalog_key="hive.carapace",
    target_height=1.4,
    mesh_name="hive_carapace_body",
    arm_name="hive_carapace_rig",
    root=Bone("root", (0, 0, 0), (0, -0.28, 0)),
    spine=(
        # Carries all six legs, the face and the cannon; the only translated
        # bone, so shoving/sinking it moves the whole creature.
        Bone("thorax", (0, 0.14, 0.70), (0, -0.26, 0.68), parent="root"),
        Bone("head", (0, -0.26, 0.68), (0, -0.56, 0.60), parent="thorax", connect=True),
        # Cannon yoke. Pivots at the base ring, so pitching it swings the
        # whole gun; this is the morph's headline motion.
        Bone("turret", (0, 0.30, 1.08), (0, -0.10, 1.16), parent="thorax"),
        # Barrel. NOT connected, deliberately: a connected bone cannot
        # translate, and the ranged attack slides this one back on its own
        # axis for the recoil.
        Bone("barrel", (0, -0.10, 1.16), (0, -0.66, 1.25), parent="turret"),
    ),
    pairs=(
        # Mandibles, under the eyes. Flung wide on the melee windup and
        # snapped shut on contact.
        Pair("fang", (0.10, -0.50, 0.49), (0.13, -0.60, 0.34), parent="head"),
    ),
    legs=(
        Leg("front", (0.20, -0.27, 0.50), (0.45, -0.40, 0.30), (0.470, -0.650, 0.030),
            "thorax", ankle_t=0.65, ankle_bow=0.02),
        Leg("mid", (0.22, 0.04, 0.50), (0.52, 0.04, 0.30), (0.660, 0.040, 0.031),
            "thorax", ankle_t=0.55, ankle_bow=0.06),
        Leg("rear", (0.19, 0.31, 0.50), (0.42, 0.50, 0.30), (0.520, 0.640, 0.026),
            "thorax", ankle_t=0.60, ankle_bow=0.04),
    ),
    anim_module="anim_carapace",
    import_rotations=((90.0, 0.0, 0.0),),
)

# The first FLYER, hive.laser_moth (height 0.85, hovering 0.55 off the floor).
#
# READ THIS BEFORE TOUCHING IT: there is no flight in the simulation.
# SimEntity.is_aerial() is true only for a STRUCTURE capsule in transit and
# CatalogSchema.UNIT has no aerial flag at all, so to the sim this creature is
# an ordinary ground unit — it pathfinds on the ground grid and a wall stops
# it. "Airborne" is a property of the ASSET and nothing else: `hover` lifts
# the whole mesh 0.55 off its own origin (rig_lib.import_body), the origin
# stays on the terrain, and every clip keeps the wings beating and the body
# drifting so it never reads as parked. That buys the look for zero sim risk;
# real flight would mean pathfinding, the determinism wall and the state hash.
#
# The vendor "robotic bee" splits into SIX disjoint shells, which hand the
# body plan over exactly (post-orient, post-scale, WITH the hover, so these
# are the numbers the spec is written in):
#   * a 394-vert BODY, y -0.37..+0.45, z 0.550..1.011 — a narrow head at the
#     front (y -0.37..-0.19, x +-0.13), a wide thorax across the middle
#     (x +-0.27, and a broad flat ventral plate along its underside), and a
#     thin abdomen tapering to a stinger point at (0, +0.45, 0.70);
#   * a 38-vert DORSAL POD on the thorax roof, y -0.16..-0.01, z 0.985..1.153
#     — the only greeble with a weapon read, so it is the laser EMITTER;
#   * a mirrored pair of 26-vert WINGS, rooted at (+-0.118, -0.141, 0.959) and
#     sweeping out/back/UP to a tip at (+-0.559, +0.010, 1.379): 0.628 long,
#     held 42 deg ABOVE horizontal at rest, i.e. already in the top half of a
#     beat. Span 1.13, and the tips are what set the model's 0.85 height;
#   * a mirrored pair of 19-vert ANTENNAE off the face, sweeping forward and
#     up from (+-0.026, -0.328, 0.916) to (+-0.143, -0.450, 1.034).
# No legs: a bee's are folded into that ventral plate, and a hovering unit has
# no use for a gait, so this is the first spec with `legs=()`.
#
# Every one of those five accessory shells is a closed island bone heat cannot
# reach, so rig_lib.bind_orphans does the real work here — which is why the
# wings, antennae and pod each get a bone running down their own axis.
#
# Same Y-up -> Z-up flip as the spitter/lancer/carapace (head already at -Z).
LASER_MOTH = Unit(
    name="laser_moth",
    obj="assets/models/Hive/laser_moth/robotic+bee+3d+model.obj",
    blend="assets/source/hive_laser_moth.blend",
    glb="assets/models/Hive/hive_laser_moth.glb",
    catalog_key="hive.laser_moth",
    target_height=0.85,
    hover=0.55,
    mesh_name="hive_laser_moth_body",
    arm_name="hive_laser_moth_rig",
    root=Bone("root", (0, 0, 0), (0, -0.28, 0)),
    spine=(
        # Pivots near the body's CENTRE, not at either end: a hoverer rotates
        # about itself, and it is the only translated bone, so surging and
        # lifting it moves the whole creature.
        Bone("thorax", (0, 0.02, 0.78), (0, -0.22, 0.80), parent="root"),
        Bone("head", (0, -0.22, 0.80), (0, -0.40, 0.76), parent="thorax", connect=True),
        # Abdomen hangs off the thorax HEAD pointing aft, like the spitter's
        # sac, so curling it never disturbs the front of the body.
        Bone("abdomen", (0, 0.02, 0.78), (0, 0.24, 0.74), parent="thorax"),
        Bone("stinger", (0, 0.24, 0.74), (0, 0.45, 0.70), parent="abdomen", connect=True),
        # The laser. Pivots at the pod's rear so pitching it aims the muzzle,
        # and it is the scaled bone: the discharge flare is one frame of it.
        Bone("emitter", (0, -0.01, 1.01), (0, -0.16, 1.12), parent="thorax"),
    ),
    pairs=(
        # Two-segment wing. The root carries the beat; the tip lags it by an
        # eighth of a cycle, which is the whole difference between a rigid
        # paddle and a membrane.
        Pair("wing", (0.118, -0.141, 0.959), (0.339, -0.066, 1.169), parent="thorax"),
        Pair("wing_tip", (0.339, -0.066, 1.169), (0.559, 0.010, 1.379),
             parent="{s}_wing"),
        Pair("antenna", (0.026, -0.328, 0.916), (0.143, -0.450, 1.034), parent="head"),
    ),
    legs=(),
    anim_module="anim_laser_moth",
    import_rotations=((90.0, 0.0, 0.0),),
)

UNITS = {u.name: u for u in (MITE, SPITTER, LANCER, CARAPACE, LASER_MOTH)}


def get(name: str) -> Unit:
    try:
        return UNITS[name]
    except KeyError:
        known = ", ".join(sorted(UNITS))
        raise SystemExit(f"unknown unit '{name}' (known: {known})")


def _cli(argv) -> int:
    """Path queries for the Makefile. Repo-relative, one unit per line."""
    mode = argv[0] if argv else "--list"
    if mode == "--names":
        print(" ".join(sorted(UNITS)))
    elif mode == "--list":
        for name in sorted(UNITS):
            u = UNITS[name]
            print(f"{u.name} {u.blend} {u.glb}")
    elif mode in ("--blend", "--glb", "--obj"):
        u = get(argv[1])
        print({"--blend": u.blend, "--glb": u.glb, "--obj": u.obj}[mode])
    else:
        print("usage: units.py [--names|--list|--blend <u>|--glb <u>|--obj <u>]")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(_cli(sys.argv[1:]))
