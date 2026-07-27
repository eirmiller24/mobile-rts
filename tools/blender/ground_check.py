"""Ground-clipping check: no clip may sink the deformed mesh below z=0.

Units play on flat ground and the model's origin is its feet, so a deformed
vertex below zero reads as the mesh clipping through the terrain. Rising is
fine and encouraged (a lunge should leave the floor) -- only sinking is a
defect. The check evaluates the real deformed mesh on every frame of every
action, which is the only way to catch it: pose-space maths says nothing about
where a skinned vertex lands.

    blender --background assets/source/hive_mite.blend \
            --python tools/blender/ground_check.py -- [--tolerance 0.005]

or `make models-check` for every committed .blend.
"""

import os
import sys

import bpy

HERE = os.path.dirname(os.path.abspath(__file__))
if HERE not in sys.path:
    sys.path.insert(0, HERE)

import rig_lib      # noqa: E402

TOLERANCE = 0.005   # ~5mm of float/skin slop


def main():
    argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
    tol = TOLERANCE
    if "--tolerance" in argv:
        tol = float(argv[argv.index("--tolerance") + 1])

    arm = next((o for o in bpy.data.objects if o.type == 'ARMATURE'), None)
    mesh = next((o for o in bpy.data.objects if o.type == 'MESH'), None)
    if arm is None or mesh is None:
        print("ground_check: no armature/mesh in this file")
        return 1

    bad = 0
    for act in sorted(bpy.data.actions, key=lambda a: a.name):
        samples = rig_lib.min_z_per_frame(arm, mesh, act)
        worst_f, worst_z = min(samples, key=lambda s: s[1])
        peak_f, peak_z = max(samples, key=lambda s: s[1])
        ok = worst_z >= -tol
        bad += 0 if ok else 1
        print(f"  {act.name:<8} min z {worst_z:+.4f} @f{worst_f:<3d} "
              f"(highest floor {peak_z:+.4f} @f{peak_f}) "
              f"{'ok' if ok else 'CLIPS'}")
    print("ground_check: " + ("OK" if not bad else f"FAILED ({bad} clip)"))
    return 0 if not bad else 1


if __name__ == "__main__":
    sys.exit(main())
