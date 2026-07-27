"""Export a rigged .blend from assets/source/ to the .glb Godot imports.

This is the everyday step: hand-tweak the .blend in the GUI, then re-export.
It never regenerates the rig (that is rig_swarmer.py) so hand work survives.

    blender --background assets/source/hive_mite.blend \
            --python tools/blender/export_glb.py -- assets/models/Hive/hive_mite.glb

or just `make models`.

Textures are downsized on the way out: the Tripo source ships a 4096x4096
basecolor, which is far more than a unit read at thumbnail size on a phone
needs, and 16x the VRAM of the 1024 we actually want. The source JPG on disk
is never modified -- only the copy inside the exported .glb.
"""

import bpy
import os
import sys

TEXTURE_MAX = 1024


def downsize_textures(limit=TEXTURE_MAX):
    """Scale oversized images down in-memory, and report what changed."""
    changed = []
    for img in bpy.data.images:
        w, h = img.size
        if not w or not h or max(w, h) <= limit:
            continue
        scale = limit / max(w, h)
        nw, nh = max(1, int(w * scale)), max(1, int(h * scale))
        img.scale(nw, nh)
        # Keep the pixels inside the .glb rather than pointing at the source.
        img.pack()
        changed.append(f"{img.name}: {w}x{h} -> {nw}x{nh}")
    return changed


def main():
    argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
    if not argv:
        print("usage: export_glb.py -- <out.glb> [--keep-texture-size]")
        return 1
    out = os.path.abspath(argv[0])
    os.makedirs(os.path.dirname(out), exist_ok=True)

    if "--keep-texture-size" not in argv:
        for line in downsize_textures():
            print("  texture", line)

    bpy.ops.export_scene.gltf(
        filepath=out,
        export_format='GLB',
        use_selection=False,
        export_apply=False,          # must stay off: it would bake the armature away
        export_yup=True,             # Blender Z-up -> glTF/Godot Y-up
        export_skins=True,
        export_animations=True,
        # Actions are stashed as one muted NLA track each, so track names
        # become the clip names Godot sees: Idle / Run / Attack.
        export_animation_mode='NLA_TRACKS',
        export_bake_animation=True,
        export_optimize_animation_size=True,
        export_materials='EXPORT',
        export_image_format='AUTO',
    )
    print(f"exported -> {out} ({os.path.getsize(out) / 1024:.0f} KiB)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
