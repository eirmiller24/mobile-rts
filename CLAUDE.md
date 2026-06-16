# Mobile RTS — project conventions

Mobile RTS (StarCraft/WC3 style) in Godot 4.6 with GDScript. Two pillars:
touch-native commander controls and a WC3-style world editor. Full design:
[design.md](design.md) — read the "Technical Foundations" section before
touching sim code.

## Environment

- Godot 4.6.3 IS installed in the devcontainer, on PATH as `godot`. Run
  headless checks and the project directly in the container. The user can
  also run on the host via flatpak (`flatpak run org.godotengine.Godot`).
- GDScript only — standard Godot build, no .NET/C#. Blender 4.2 is available
  in the container for the asset pipeline (Blender → glTF).
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
