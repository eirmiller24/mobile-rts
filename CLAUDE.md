# Mobile RTS — project conventions

Mobile RTS (StarCraft/WC3 style) in Godot 4.7 with GDScript. Two pillars:
touch-native commander controls and a WC3-style world editor. Full design:
[design.md](design.md) — always read the design doc before doing any work, 
and make sure to definitely read the "Technical Foundations" section before 
touching sim code.

## Environment

- Godot **4.7-stable** on PATH as `godot`, and `$GODOT` points at it (the
  Makefile's `GODOT ?= godot` picks it up). The devcontainer does not install
  Godot — it borrows the host's binary from `~/Programs/bin/godot` — so the
  container and the host editor are the same build. Run headless checks and the
  project directly in the container; run the GUI editor on the host.
  `project.godot`, `.github/workflows/ci.yml` and the container all agree on
  4.7 (CI was bumped from 4.6.3 on 2026-07-26).
- GDScript only — standard Godot build, no .NET/C#. Blender **5.1.2** is on PATH
  as `blender`, also borrowed from the host, for the asset pipeline
  (Blender → glTF).
- Android builds: `ANDROID_HOME` is set to `~/Programs/Android/sdk` and
  `JAVA_HOME` to sdkman's Temurin 17. **`make android` cannot work yet** — that
  SDK has no `ndk/` directory installed, and godot-cpp resolves the NDK at
  `$ANDROID_HOME/ndk/<version>`.
- SCons is on PATH as `scons` (Fedora package `python3-scons`); the Makefile
  invokes it that way already.
- Headless checks (one per script in `tests/`), runnable in the container:
  `godot --headless --path . -s res://tests/determinism_check.gd`

## Layout

- `src/sim/` — deterministic lockstep simulation. Headless, tick-driven.
- `src/data/` — catalog compiler/schema and map loader (outside the
  determinism wall; the sim receives only their compiled output).
- `src/view/` — 3D presentation; reads sim state, never writes it.
- `src/ui/` — touch controls, side buttons, command console.
- `src/net/` — lockstep networking (commands on the wire, not state).
- `data/` — unit/ability/structure catalogs (data-driven for the editor).
- `editor/` — world editor (later milestone).
- `assets/`, `maps/`, `tests/` — as named.

## Asset pipeline (Blender → glTF)

Three artifacts per model, and the rule is that **the `.blend` is the source of
truth, never the raw vendor file**:

- `assets/models/<Faction>/<vendor dir>/` — untouched vendor download (Tripo
  OBJ + 4K texture). Read once by the generator; never edited.
- `assets/source/<name>.blend` — **committed, and the thing you hand-edit.**
  Open it in the GUI on the host, tweak, save. `assets/source/.gdignore` keeps
  Godot from importing `.blend` files (it would, since Blender is on PATH — but
  CI has no Blender).
- `assets/models/<Faction>/<name>.glb` — committed build artifact Godot imports.

Two make targets, and the distinction matters:

- `make models` — re-export the committed `.blend`s to `.glb`. **The everyday
  step**; run it after any hand-edit. Never regenerates a rig, so hand work is
  safe. Textures are downsized to 1024 on the way out (the 4K source stays
  untouched on disk and in the `.blend`).
- `make rig-mite` — **rebuilds the rig from the raw OBJ and overwrites the
  `.blend`, discarding hand-edits.** For when you change
  `tools/blender/rig_swarmer.py` / `animate_swarmer.py` and want the generated
  rig back. It needs `--force` precisely because it destroys hand work.

Authoring conventions the generator bakes in, which hand-edits must preserve:
models are Z-up facing **-Y** in Blender (so glTF lands them facing -Z, Godot's
forward), scaled to the entry's catalog `height` so the view instances them at
scale 1, origin at the feet, and ≤4 bone influences per vertex (glTF's cap).
Animations are stashed one per **muted NLA track** — the track name is the clip
name Godot sees.

Wiring a model to a unit is catalog data, not code: add `model` and an
`animations` map to the entry's `view` block (see `hive.mite`). Entries without
a `model` still render as primitives, so models land one at a time.
`tests/view_model_check.gd` fails if a `.glb` or a named clip goes missing —
without it the view would silently fall back to a capsule.


## Determinism rules (non-negotiable in src/sim/)

- No floats. Use `Fixed` (16.16 fixed point in int). `from_float`/`to_float`
  are for the view layer only.
- No `randf()`/`randi()`/`RandomNumberGenerator` — only the sim's own `DRng`.
- No engine physics, nodes, signals-to-view, or wall-clock time in the sim.
- Iterate entities in ascending id order; sort any Dictionary keys before
  iteration that affects state.
- The sim's only inputs are the construction seed and `SimCommand`s. The view
  influences the sim exclusively by scheduling commands.
- Any new sim state must be folded into `Sim.state_hash()`.

## UI rules (see design.md "UI as Data")

- The UI is not a global object. Faction skins differ, and custom maps can
  redefine console tabs/behavior and side button count/location/meaning.
- Interaction *mechanics* (gestures, radials, console detents, designations)
  are engine code; what buttons/tabs *mean* is data from the UI catalog.
- Never hardcode a binding like "this button = attack-move" in a scene or
  script literal — every button/tab reads its meaning from a definition
  resource, even in early prototypes.

## Style

- Tabs for GDScript indentation (Godot default), typed GDScript everywhere
  practical, `class_name` for shared classes.
- Scenes stay minimal and code-configured; prefer `@export` over magic
  numbers buried in .tscn files.
