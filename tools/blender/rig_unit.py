"""Build a rigged, animated unit from its raw vendor OBJ.

This is the *generator*: OBJ in, `assets/source/<name>.blend` out, with the
armature its spec describes, skin weights, and the animation module's actions
stashed as NLA strips so glTF exports them as named clips.

    blender --background --python tools/blender/rig_unit.py -- <unit> [--force]
    make rig UNIT=<unit>        # the same, then re-exports every .glb
    make rig-<unit>

The .blend it writes is the hand-edit surface from then on -- re-running this
clobbers hand work, so it refuses to overwrite unless given --force. The
everyday path after a tweak is tools/blender/export_glb.py (see `make models`).

Which units exist, where their OBJ/blend/glb live, and what their skeleton
looks like is all data in units.py; the shared construction and pose maths is
rig_lib.py. Adding a creature means a `units.Unit` entry plus an anim_<name>.py
that exposes `build_all(arm, spec)` -- not a copy of this script.
"""

import importlib
import os
import sys

import bpy

HERE = os.path.dirname(os.path.abspath(__file__))
if HERE not in sys.path:  # `blender --python` does not add the script's own dir
    sys.path.insert(0, HERE)

import rig_lib      # noqa: E402
import units        # noqa: E402


def build(spec, force=False):
    out = spec.blend_path
    if os.path.exists(out) and not force:
        print(f"refusing to overwrite {out} (pass --force)")
        return 1
    if not os.path.exists(spec.obj_path):
        print(f"missing source OBJ: {spec.obj_path}")
        return 1

    rig_lib.reset_scene()
    body = rig_lib.import_body(spec)
    arm = rig_lib.build_armature(spec)
    mode = rig_lib.skin(body, arm, root_bone=spec.root.name)

    anim = importlib.import_module(spec.anim_module)
    importlib.reload(anim)
    actions = anim.build_all(arm, spec)

    os.makedirs(os.path.dirname(out), exist_ok=True)
    bpy.ops.wm.save_as_mainfile(filepath=out)
    clips = ", ".join(a.name for a in actions)
    print(f"{spec.name}: weights={mode} bones={len(arm.data.bones)} "
          f"clips=[{clips}] -> {out}")
    return 0


def main():
    argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
    names = [a for a in argv if not a.startswith("-")]
    if not names:
        print("usage: rig_unit.py -- <unit> [--force]   known: "
              + ", ".join(sorted(units.UNITS)))
        return 1
    force = "--force" in argv
    for name in names:
        rc = build(units.get(name), force=force)
        if rc:
            return rc
    return 0


if __name__ == "__main__":
    sys.exit(main())
