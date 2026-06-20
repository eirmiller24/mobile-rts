# Native sim — C++ GDExtension (M5)

The C++ GDExtension port of `src/sim/` (design_m5.md §2). The GDScript sim in
`src/sim/` is **frozen at its M4 feature set** as the bit-exact parity oracle
and readable reference (design_m5.md §2.4); this directory is the forward
implementation.

## Layout

```
native/
  godot-cpp/            git submodule (branch 4.5 — loads in our 4.6.3 engine)
  SConstruct            build; outputs to ../bin/
  src/
    register_types.*    GDExtension entry point
    native_sim.*        NativeSim — the single registered boundary class
    sim/
      fixed.h           Fixed   (16.16 fixed point)         [substrate]
      drng.h            DRng    (splitmix32)                [substrate]
      proc_rng.h        ProcRng (WC3 pseudo-random procs)   [substrate]
      sim_hash.h        SimHash (FNV-1a + state-hash mixer) [substrate]
      sim_grid.{h,cpp}  SimGrid (two-resolution cell store) [substrate]
      entity.h          Entity  (mirror of SimEntity)
      player.h          Player  (mirror of SimPlayer)
      command.h         Command (mirror of SimCommand)
      catalog_view.h    CatalogView (native mirror of CompiledCatalog)
      id_vec.h          IdVec   (dense id-indexed entity/player store)
      sim.{h,cpp}       Sim     (the simulation)
```

The substrate is plain C++ in the `mrts` namespace and never crosses the
boundary. Only `NativeSim` (a `RefCounted`) is registered with Godot, so
GDScript crosses the boundary O(1) times per tick — `construct()`, `step()`,
`schedule()`, `state_hash()`, plus batch read APIs for the view
(design_m5.md §2.3).

## Build

The devcontainer has the toolchain (g++, SCons). godot-cpp builds once
(~3-5 min); rebuilds of our sources are seconds.

```sh
git submodule update --init --recursive      # first time only
cd native
scons -j"$(nproc)"                            # debug, host (linux x86_64)
scons target=template_release                 # optimized
scons platform=android arch=arm64 target=template_release   # mobile (design_m5.md §2.5)
```

The library lands in `../bin/` beside `mobile_rts_sim.gdextension`, which Godot
discovers automatically. Built libraries are git-ignored; the `.gdextension`
manifest is committed.

Godot loads fine **without** a built library (it logs "library not found" and
falls back to the GDScript reference sim), so non-sim work needs no native
toolchain (design_m5.md §2.5).

## Determinism porting rules (design.md "Porting semantics to watch")

- GDScript ints are 64-bit and wrap on overflow; signed overflow is UB in C++.
  Every hash/Fixed step that can overflow is computed in `uint64_t` and cast
  back (see `Fixed::mul`/`div`, `SimHash::mix`), reproducing GDScript exactly.
- `/` truncates toward zero and `>>` is arithmetic in both languages — used
  directly.
- All entity/player iteration is ascending-id. `IdVec` (a dense `std::vector`
  indexed by id, replacing `std::map` for cache locality — AoS) iterates
  ascending id and skips tombstones; because entities are inserted in
  ascending-id order this also matches the GDScript `Dictionary`'s
  insertion-order iteration. Ids are never reused (GDScript semantics), so dead
  entries are tombstones, not recycled slots.
- No floats, no engine RNG/physics/nodes/time in `mrts`. `godot::Dictionary`/
  `Array` are used only as plain compiled-data containers (keyed lookups), which
  is deterministic.

## Verification (the parity harness — design_m5.md §2.4, §7)

The sim is *seed + commands → hash stream*, so the port is verified by running
the GDScript oracle and the C++ sim on identical inputs and asserting identical
`state_hash()`.

- `tests/native_substrate_check.gd` — Fixed/DRng/ProcRng/SimHash/SimGrid are
  bit-exact. **Green.**
- `tests/native_tick0_parity_check.gd` — full construction + the entire hash
  chain match at tick 0 on `dev_arena` and `dev_clash`. **Green.**
- `tests/port_parity_check.gd` — **per-tick** bit-exact parity across the full
  M4 system set: dual auto-economy (600t), walled-gap combat with crits (400t),
  scripted Hive economy/builds/abilities (800t), and the canonical two-AI bot
  match to elimination (1000t). **Green.**

These skip cleanly if the extension is not built, so the pure-GDScript CI gate is
unaffected. CI (`.github/workflows/ci.yml`, `native` job) builds the extension
and runs all three.

## Port status

| Area | Status |
|---|---|
| Toolchain (godot-cpp, SCons, .gdextension, CI) | **done** |
| Substrate: Fixed, DRng, ProcRng, SimHash, SimGrid | **done, parity-verified** |
| Entity / Player / Command structs + full `hash_into` | **done** |
| CompiledCatalog / MapData marshalling (`CatalogView`) | **done** |
| Construction: spawn, footprints, structure-complete, refinery linking, depot economy seeding | **done, tick-0 parity** |
| Vision: occluders, LOS, sight stamp, capsule detection, discovered-resources | **done, tick-0 parity** |
| `state_hash()` | **done, parity-verified** |
| `step()` systems (economy, worker economy, worker build, walls, production, movement, combat, stance, status, structures, reap, elimination) | **done, per-tick parity** |
| Pathing: Lazy Theta\* + LOS | **done, per-tick parity** |
| Pathing: flow fields (`FlowBuild`) | **not ported** — dead under `USE_FLOW_FIELDS=false` (see below) |
| Batch view-read API (`view_snapshot`, `vision_of`, `resources_of`, `bandwidth_of`, `match_result`, `is_entity_visible`) | **done, parity-verified** (`native_view_api_check.gd`) |
| Per-interaction console/placement queries (`depot_economy`, `training_queues`, `buildable_structures`, `trainable_units`, `builder_for`, `build_block_reason`, `train_structure_for`, `stronghold_ids`, `depot_ids`, `vents`/`vent_at`/`vent_taken`, `territory_covers`, `flagged_aura_circles`, `income`, `players_snapshot`) | **done, parity-verified** (`native_view_api_check.gd`) |
| The swap — the running game uses the native sim via the `GameSim` adapter | **done** (`game_sim_check.gd`, `game_loop_smoke.gd`) |
| Android CI build | **TODO** (SConstruct supports it; CI needs NDK) |

### The swap (`src/game_sim.gd`)

`main.gd` now builds `GameSim` instead of the GDScript `Sim`. `GameSim` wraps a
`NativeSim` and presents the exact read surface the view/console/bot already
used (`entities`, `players`, `grid`, `catalog`, `tick`, the query methods,
`schedule(SimCommand)`), so the rest of the GDScript game is unchanged. Each
`step()` advances the native sim and pulls **one** `view_snapshot` + a few
single-call reads, from which it rebuilds lightweight `SimEntity`/`SimPlayer`
facades, mirrors the grid, and caches income — the design's O(1)-crossings-per-
tick discipline. The GDScript `Sim` stays the frozen oracle the tests run
against; `BotCommander` is duck-typed so it drives either. `game_loop_smoke.gd`
proves the native-backed game (GameSim + bots, the real `main.gd` path) stays
bit-identical to the GDScript-sim game.

### Batch view-read API (`sim_view.cpp`)

`view_snapshot(viewer)` returns one Dictionary of parallel packed arrays — one
entry per live entity, ascending id — carrying every field the view renders
(`ids`, `type_key`, `player`, `kind`, `x`, `y`, `radius`, `hp`, `max_hp`,
`amount`, `build_state`, `build_ticks_left`, `foot_w`, `foot_h`, `flags`). The
per-entity render visibility for `viewer` is pre-baked into `flags`
(bit0 morphed, bit1 underground, bit2 render-visible, bit3 unit, bit4 resource,
bit5 structure), so the view never makes a per-entity `is_entity_visible` call.
This collapses the old ~entities×fields per-frame property reads into one
boundary crossing per tick (design_m5.md §2.3). `vision_of`/`resources_of`/
`bandwidth_of`/`match_result` are likewise single-call.

### Flow fields (not ported)

`USE_FLOW_FIELDS=false`: every order routes per-unit with Lazy Theta\*, so the
flow-field machinery (`pathing.gd` `FlowBuild`, `_flow_entry`/`_flow_waypoint`/
`_run_flow_builds`) is dead code and was not ported. There is one latent entry
into the flow path — `_waypoint` on a "small" order whose start cell equals its
goal cell — which is stubbed to "hold position" (exactly what GDScript returns
while a field is still building). The per-tick parity suite (incl. the 1000-tick
bot match) never hits a divergence there, confirming the stub is sufficient for
the current config. Re-enabling flow fields means porting `FlowBuild` and the
`_flow_*` helpers here; `pathing.gd` remains the reference.
