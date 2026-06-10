# mobile-rts

A mobile RTS in the vein of StarCraft / Warcraft III, built in Godot 4.6
(GDScript). Two headline features: touch-native "commander on the bridge"
controls, and a WC3-style world editor that all official content is built in.

See [design.md](design.md) for the full design document and roadmap.

## Running

Open the project in Godot 4.6+ (standard build). On the host:

```sh
flatpak run org.godotengine.Godot --path . -e   # editor
flatpak run org.godotengine.Godot --path .      # run the game
```

Touch input is emulated from the mouse for desktop iteration. Camera: mouse
wheel zooms, middle-drag pans, right-drag rotates (two-finger gestures on
touch devices).

## Tests

```sh
flatpak run org.godotengine.Godot --headless --path . -s res://tests/determinism_check.gd
```

## Layout

| Path | Contents |
|---|---|
| `src/sim/` | Deterministic lockstep simulation (fixed-point, headless) |
| `src/view/` | 3D presentation layer |
| `src/ui/` | Touch controls and command console |
| `src/net/` | Lockstep networking |
| `data/` | Unit/ability catalogs (data-driven content) |
| `editor/` | World editor |
| `assets/` | Models, textures, audio (Blender → glTF) |
| `maps/` | Map bundles |
