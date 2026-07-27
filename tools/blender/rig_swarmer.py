"""Build the rigged, animated Hive Mite from the raw Tripo swarmer OBJ.

This is the *generator*: raw OBJ in, `assets/source/hive_mite.blend` out, with a
hexapod armature, skin weights, and the Idle/Run/Attack actions stashed as NLA
strips so glTF exports them as three named clips.

    blender --background --python tools/blender/rig_swarmer.py -- [--force]

The .blend it writes is the hand-edit surface from then on — re-running this
clobbers hand work, so it refuses to overwrite unless given --force. The
everyday path after a tweak is tools/blender/export_glb.py (see `make models`).

Authoring conventions baked in here:
  * Blender is Z-up; the mite faces -Y, so the glTF export lands it facing -Z,
    which is Godot's forward.
  * The model is scaled to the `hive.mite` catalog height (0.9) so the view
    layer can instance it at scale 1.
  * Bones are named <side>_<part>; sides are L/R with X mirrored.
"""

import bpy
import bmesh
import math
import mathutils
import os
import sys

# --- paths -------------------------------------------------------------------

HERE = os.path.dirname(os.path.abspath(__file__))
if HERE not in sys.path:  # `blender --python` does not add the script's own dir
    sys.path.insert(0, HERE)

REPO = os.path.dirname(os.path.dirname(HERE))
SRC_OBJ = os.path.join(
    REPO, "assets", "models", "Hive", "mechanical swarmer 3d model",
    "mechanical+swarmer+3d+model.obj")
OUT_BLEND = os.path.join(REPO, "assets", "source", "hive_mite.blend")

MESH_NAME = "hive_mite_body"
ARM_NAME = "hive_mite_rig"

# --- proportions -------------------------------------------------------------
# Catalog height for hive.mite; the mesh is normalised to this so Godot can
# instance the model at scale 1 (see data/catalog/hive.json).
TARGET_HEIGHT = 0.9

# Leg geometry, measured off the source mesh (foot tips are the mesh's own
# ground-contact clusters; hips/knees sit inside the leg volume). X is written
# for the right side and mirrored to the left.
#   name,   hip,                  knee,                 foot tip
LEGS = [
    ("front",  (0.16, -0.30, 0.47), (0.30, -0.42, 0.50), (0.298, -0.363, 0.059)),
    ("mid",    (0.17, +0.02, 0.47), (0.30, +0.06, 0.46), (0.287, +0.071, 0.193)),
    ("rear",   (0.17, +0.28, 0.47), (0.33, +0.36, 0.44), (0.359, +0.431, 0.000)),
]
# Where the ankle falls along the knee->tip run, and how far it bows outward.
ANKLE_T = 0.70
ANKLE_BOW = 0.03


def v(t):
    return mathutils.Vector(t)


# --- scene bootstrap ---------------------------------------------------------

def reset_scene():
    bpy.ops.wm.read_homefile(use_empty=True)
    sc = bpy.context.scene
    sc.unit_settings.system = 'METRIC'
    sc.frame_start = 1
    return sc


def import_body():
    """Import the OBJ, orient it head--Y / Z-up, and normalise its height."""
    bpy.ops.wm.obj_import(filepath=SRC_OBJ)
    ob = [o for o in bpy.context.scene.objects if o.type == 'MESH'][0]
    ob.name = MESH_NAME
    ob.data.name = MESH_NAME
    bpy.context.view_layer.objects.active = ob
    for o in bpy.context.scene.objects:
        o.select_set(o is ob)

    # The OBJ is authored Y-up with the head at +X. Two applied rotations put
    # it in Blender's Z-up with the head at -Y.
    ob.rotation_euler = (math.radians(90), 0, 0)
    bpy.ops.object.transform_apply(location=False, rotation=True, scale=False)
    ob.rotation_euler = (0, 0, math.radians(-90))
    bpy.ops.object.transform_apply(location=False, rotation=True, scale=False)

    co = [vt.co for vt in ob.data.vertices]
    height = max(c.z for c in co) - min(c.z for c in co)
    s = TARGET_HEIGHT / height
    ob.scale = (s, s, s)
    bpy.ops.object.transform_apply(location=False, rotation=False, scale=True)

    # Drop it exactly onto z=0 and centre it on X/Y so the rig's origin is the
    # unit's feet -- that is the transform Godot will place on the ground.
    co = [vt.co for vt in ob.data.vertices]
    zmin = min(c.z for c in co)
    xmid = (max(c.x for c in co) + min(c.x for c in co)) / 2
    ymid = (max(c.y for c in co) + min(c.y for c in co)) / 2
    me = ob.data
    for vt in me.vertices:
        vt.co.x -= xmid
        vt.co.y -= ymid
        vt.co.z -= zmin

    # The Tripo export carries degenerate/duplicate geometry that makes the
    # glTF exporter warn "mesh is not valid"; validate() repairs it in place.
    if ob.data.validate(verbose=False):
        print("note: repaired invalid geometry in the source mesh")

    bpy.ops.object.shade_smooth()
    if hasattr(ob.data, "use_auto_smooth"):
        ob.data.use_auto_smooth = True
    return ob


# --- armature ----------------------------------------------------------------

def build_armature(body):
    arm_data = bpy.data.armatures.new(ARM_NAME)
    arm = bpy.data.objects.new(ARM_NAME, arm_data)
    bpy.context.scene.collection.objects.link(arm)
    bpy.context.view_layer.objects.active = arm
    for o in bpy.context.scene.objects:
        o.select_set(o is arm)
    bpy.ops.object.mode_set(mode='EDIT')
    eb = arm_data.edit_bones

    def bone(name, head, tail, parent=None, connect=False, roll=0.0):
        b = eb.new(name)
        b.head = v(head)
        b.tail = v(tail)
        b.roll = roll
        if parent is not None:
            b.parent = parent
            b.use_connect = connect
        return b

    # Spine runs tail(+Y) -> head(-Y); `root` stays at the origin so the
    # exported model's pivot is on the ground under the body.
    root = bone("root", (0, 0, 0), (0, -0.18, 0))
    abdomen = bone("abdomen", (0, 0.42, 0.55), (0, 0.10, 0.58), root)
    thorax = bone("thorax", (0, 0.10, 0.58), (0, -0.20, 0.58), abdomen, connect=True)
    head = bone("head", (0, -0.20, 0.58), (0, -0.44, 0.50), thorax, connect=True)

    # Mandibles: the only articulated bit of the face, used by Attack.
    for s, tag in ((-1.0, "L"), (1.0, "R")):
        bone(f"{tag}_mandible", (s * 0.07, -0.38, 0.44), (s * 0.13, -0.52, 0.36), head)

    for leg_name, hip, knee, foot in LEGS:
        # Front/mid legs hang off the thorax, rear legs off the abdomen.
        parent = abdomen if leg_name == "rear" else thorax
        for s, tag in ((-1.0, "L"), (1.0, "R")):
            hp = v((s * hip[0], hip[1], hip[2]))
            kn = v((s * knee[0], knee[1], knee[2]))
            ft = v((s * foot[0], foot[1], foot[2]))
            ankle = kn.lerp(ft, ANKLE_T)
            ankle.x += s * ANKLE_BOW
            base = f"{tag}_{leg_name}"
            up = bone(f"{base}_upper", hp, kn, parent)
            lo = bone(f"{base}_lower", kn, ankle, up, connect=True)
            bone(f"{base}_foot", ankle, ft, lo, connect=True)

    bpy.ops.object.mode_set(mode='OBJECT')
    return arm


def skin(body, arm):
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
    # `root` must not steal weight from the body -- it is a placement bone.
    vg = body.vertex_groups.get("root")
    if vg is not None:
        body.vertex_groups.remove(vg)

    # glTF keeps only the 4 heaviest influences per vertex. Cap them here so
    # what Blender previews is what Godot actually plays.
    bpy.context.view_layer.objects.active = body
    for o in bpy.context.scene.objects:
        o.select_set(o is body)
    bpy.ops.object.vertex_group_limit_total(limit=4)
    bpy.ops.object.vertex_group_normalize_all(lock_active=False)

    bpy.context.view_layer.objects.active = arm
    return mode


def main():
    argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
    if os.path.exists(OUT_BLEND) and "--force" not in argv:
        print(f"refusing to overwrite {OUT_BLEND} (pass --force)")
        return 1

    reset_scene()
    body = import_body()
    arm = build_armature(body)
    mode = skin(body, arm)

    import animate_swarmer
    animate_swarmer.build_all(arm)

    os.makedirs(os.path.dirname(OUT_BLEND), exist_ok=True)
    bpy.ops.wm.save_as_mainfile(filepath=OUT_BLEND)
    print(f"weights={mode} bones={len(arm.data.bones)} -> {OUT_BLEND}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
