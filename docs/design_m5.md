# M5 Design — Native Sim Port, Trigger Runtime, and Map Bundles

*Status: draft for review. Code does not start until this document is finalized.*

**Roadmap deviation, flagged up front (read this first).** The
[roadmap](../design.md) names M5 *"Editor MVP — terrain editing, object
placement, catalog overrides, trigger GUI v1."* This document **redefines M5**
and the surrounding sequence, on two decisions taken during M5 design:

1. **No graphical world editor in v1.** We live in an AI-coding world where a
   well-specified text format is faster to author than a touch GUI is to build
   *and* to use. So v1 ships **no visual editor**: a map is JSON (terrain,
   objects, regions, catalog overrides) plus a **Lua-flavored trigger script**,
   and the engine parses those into complete, playable levels. A graphical
   editor becomes its own later milestone if the game moves toward production
   (the registry-driven architecture below keeps that editor cheap to add —
   §4.3). This satisfies pillar #3 ("the editor is the game") at the *data*
   level: the game's content is data, and v1 authors that data directly.
2. **The C++ GDExtension port moves into M5, before the trigger VM.** design.md
   planned the port for "~M6." We pull it forward so we **write the trigger VM
   once, in C++**, rather than building it in GDScript and immediately
   re-porting it (§2.1). This also gives the VM the cleanest possible
   architecture — same language, same side of the boundary as the sim it drives
   (§3.2), closing design.md Open Q #11 in its best form.

Net, **M5 becomes the native-sim-and-scripting foundation**: the C++ sim, the
trigger runtime that lives inside it, and the text map-bundle format that feeds
both. The **visual world editor (terrain/object/trigger GUI) defers to a later
milestone**; **multiplayer (M6)** now builds directly on the C++ sim this
milestone produces. design.md's roadmap and Open Q #11 should be updated to
match — flagged, not done here.

This document extends [design.md](../design.md), [design_m3.md](design_m3.md),
and [design_m4.md](design_m4.md). Where it contradicts design.md's roadmap, the
deviation is the two decisions above; everywhere else it obeys the prior docs.
All names and numbers are placeholders unless stated otherwise.

What M0–M4 give us that M5 builds on:

- A **complete, tested GDScript sim** through M4: fixed-point movement/collision/
  pathing, combat, procs, economy (Hive nanos + Rebel workers), vision/fog,
  structure lifecycle, stances, walls, capsule detection, elimination, command
  queue, state hashing. This is what the port translates — designed, debugged,
  hash-verified, **portable now** (M4 §15).
- The **catalog** (M3 §2) and **map format** (M3 §3): derive-and-override JSON
  compiled to interned ints the sim consumes; a `MapLoader`; a content hash
  folded into the initial state. M5's bundle is the superset (§4).
- The **command pipeline** (M3 §4.9, M4 §8/§12): the sim's only mutating inputs
  are `SimCommand`s from a human, a bot, or — new in M5 — a trigger.
- The **determinism constitution** and the **GDExtension boundary discipline**
  (design.md, M3 §4.12, M4 §15): the public sim surface is already shaped for
  C++ (O(1) crossings/tick, batch reads, plain-data inputs), on purpose.


## 1. Scope

### In

1. **The C++ GDExtension port of the M4 sim** (§2) — the whole of `src/sim/`
   translated to C++ via `godot-cpp`, verified bit-exact against the frozen
   GDScript sim by the existing parity harness, building for desktop **and
   Android** (the mobile target is the point). The GDScript sim freezes at M4
   as the parity oracle and readable reference; C++ becomes the sole forward
   implementation (§2.4).
2. **The trigger runtime** (§3) — an event-driven, **fully expressive** VM
   written **in C++ inside the sim wall**: locals, user-defined functions
   (parameters, returns, recursion), arbitrary loops, and **per-instance data**
   (the MUI driver, §3.2), mutating the match only through the sim's command/
   mutation APIs. The one new *sim system* in M5.
3. **The Lua-flavored trigger language + compiler** (§3.9) — a small, typed,
   float-free scripting language with Lua surface syntax; a `TriggerCompiler`
   (GDScript, outside the wall) that lexes/parses/typechecks it against the
   node registry and emits a flat interned program the C++ VM walks. **Language
   documentation is a first-class deliverable** (§3.9) — the AI/human authoring
   bet depends on a precise spec of the subset.
4. **The map bundle format** (§4) — terrain, objects, **regions** (new),
   catalog overrides, the trigger script, manifest + content hash; distributed
   as a `.zip`; the M3/M4 single-file map is the degenerate case. Authored as
   text/JSON + Lua (no editor).
5. **Catalog overrides as data** (§5) — maps override/derive catalog entries via
   the existing M3 layer mechanism, authored as JSON. (No object-editor GUI;
   the override layer *is* the editing surface in v1.)
6. **The pillar-3 rebuild, foundation-level** (§1 exit) — rebuild
   `dev_clash.json` as a bundle and author a **Lua-scripted tower-defense** map,
   proving the format + language express the game's own content and a non-trivial
   scenario, by hand/AI authoring rather than a GUI.

### Out (explicit deferrals)

| Deferred | To | Why |
|---|---|---|
| **The entire graphical world editor** (terrain/object/region placement GUI, catalog object-editor GUI, trigger GUI) | a later "production" milestone | The intro decision: text/JSON + Lua is faster to author and to *build* than a touch editor. The registry-driven design (§3.3) makes a future GUI cheap — it auto-generates from the same registries the runtime uses. Pillar #3 is met at the data level now. |
| **Custom assets** (community glTF/textures/audio bundling + importer hardening) | post-v1 | Out of scope for the MVP entirely (your call). The bundle format reserves an `assets/` slot (§4.1) but v1 ships on the M3 primitive-fallback views (M3 §7.1); a map with no custom assets is fully playable. The untrusted-asset-parser attack surface (the one real one, §4.4) is a bridge we cross with the map browser, later. |
| **iOS build** | M6+ | M5 hardens the Android export (the mobile target that matters first). iOS GDExtension cross-compile lands with the broader iOS pass. |
| **Bytecode VM / per-tick-per-unit trigger optimization** | when profiling demands | M5 ships an AST-walker in C++ (§3.2). The flat interned program is bytecode-adjacent; lowering it is an additive perf escape hatch, not a rewrite (§3.2). |
| **Cloud save + version history** (design.md Open Q #9) | M6+ | The editor-less v1 works on local bundle files; cloud sync is the M6-era server dependency. The content-hashed bundle is the sync seam (§6). |
| **Map browser / sharing with moderation** | post-v1 | Local `.zip` import/export only in v1. |

### Exit criteria

M5 is done when, on desktop **and Android**:

1. **The C++ sim is bit-exact.** Running the frozen GDScript sim and the C++ sim
   on identical inputs (seed + command stream) produces **identical
   `state_hash()` every tick** across the full M4 determinism suite (economy,
   vision, walls, stances, bot stream, a match to elimination). A single
   differing tick is a port bug, localized by the harness.
2. **The C++ sim ships on mobile.** The Android export loads and runs a match
   with the native sim; the M4 perf budget is met or beaten on a mid-range
   device (the port's whole reason — design.md "3–4× slower mobile CPUs meet
   real armies").
3. **A trigger fires and changes the match, deterministically.** A Lua-authored
   trigger ("when a unit enters region R, spawn a wave for the AI player and warn
   the human") runs identically on two runs from one seed → identical hash
   streams; the cosmetic half (the warning) shows on screen without entering the
   hash (§3.4).
4. **The VM is expressive enough for real mechanics.** The MUI test passes:
   **ten units running the same damage-over-time effect simultaneously do not
   collide** — each instance keeps its own state via locals/instance data
   (§3.2). A user-defined function with parameters and a return value, called
   recursively, executes deterministically.
5. **The VM is sandboxed and bounded.** No map can desync, hang (op budget,
   §3.7), touch the filesystem/network, or execute native code; a deliberately
   hostile script is contained. The language has no float type, no FFI, no
   `loadstring`, no stdlib beyond the registry (§3.8).
6. **A scripted-AI / tower-defense bundle plays.** A hand/AI-authored bundle
   (JSON + Lua) loads, the script spawns waves and issues `SimCommand`s to a
   computer player, and the scenario reaches a trigger-driven victory (§3.5).
7. **The bundle round-trips and the compiler refuses bad input loudly.** A
   `.zip` bundle exports and re-imports losslessly; an unknown function, a
   type-mismatched argument, a float literal, a cyclic call, an oversized field,
   or a tampered content hash fails at load with a clear cause — never mid-match
   (M3 §2.4 discipline, extended to the language).
8. **`determinism_check` covers trigger state.** An M5 scenario (a Lua-scripted
   map played to a trigger-driven end) run twice from one seed → identical hash
   streams, with all trigger state (globals, call frames/locals, instance data,
   regions, timers, on/off flags, `wait` context) in the hash.
9. **The pillar-3 rebuild passes:** `dev_clash` rebuilt as a bundle plays
   identically to the M4 hand-authored map (golden-hash where content matches),
   and the tower-defense map demonstrates the language end to end.


## 2. The C++ GDExtension port

The largest piece of M5 by effort, and the enabler for the trigger VM. design.md
already specifies the *shape* of this port (boundary at the whole `src/sim/`
module, struct-of-arrays state C++-side, O(1) boundary crossings per tick, batch
read APIs, the GDScript sim as readable reference, the parity harness). M5
**executes** it and pulls it earlier than design.md planned.

### 2.1 Why now, before the VM

- **Write the trigger VM once.** The VM is a non-trivial interpreter (an
  expressive language: locals, functions, loops, instance data — §3.2). Building
  it in GDScript and then re-porting it to C++ is the duplicated effort we are
  explicitly avoiding. Port the existing sim first, then author the VM directly
  in C++ as a new sim subsystem.
- **The cleanest VM architecture.** A C++ VM inside a C++ sim is same-language,
  same side of the boundary, **zero boundary crossings per trigger op**, and
  inherits the determinism constitution for free (§3.2). This is strictly better
  than the alternatives design.md Open Q #11 weighed (GDScript VM calling across
  the boundary; C++ VM stranded behind a GDScript sim). Porting first turns
  Open Q #11 from a dilemma into the obvious answer.
- **The churn argument has expired.** design.md deferred the port because
  "M3–M5 is the sim's highest-churn stretch" and a C++ sim would tax game-feel
  iteration. That churn is **spent**: the hot core and the M4 breadth are
  feature-complete and tested. M5 adds the VM (a new subsystem, authored in C++
  from the start) — not re-tuning of the existing hot loops. The thing the
  caution protected no longer applies.
- **Mobile needs it regardless.** The port must precede real mobile play (3–4×
  slower CPUs) and M6 multiplayer (dropped ticks become a sync problem, not a
  cosmetic one). Doing it in M5 means all M5+ content runs against the shipping
  runtime.

### 2.2 Language: C++ via godot-cpp (decided)

`godot-cpp` is the GDExtension binding. Rationale, including the rejected
alternatives:

- **`godot-cpp` (C++)** — first-party, maintained by the engine team, the
  best-supported path for **Android/iOS** specifically (it is what Godot's own
  developers target). For a mobile-first project this is decisive.
- **`godot-rust` (gdext)** — genuinely good and actively maintained, but its
  **mobile support is the soft spot** (Android cross-compile is involved; iOS is
  less battle-tested). Mobile is the one axis we cannot put at risk, so Rust's
  risk lands exactly where it hurts.
- **`godot-go`** — bindings have been unmaintained, *and* Go's GC/scheduler is a
  poor fit for a deterministic fixed-tick sim regardless. Rejected on both counts.

**A disciplined C++ subset keeps the complexity bounded** and the translation
mechanical — the determinism rules map 1:1 onto C++ choices:

- Fixed-width integers (`int64_t`/`int32_t`) matching GDScript's 64-bit ints and
  **truncating division** (`/`, `>>` ported exactly — design.md). No floats in
  the sim, ever (the constitution).
- Plain structs + `std::vector` for struct-of-arrays entity state; **ids, not
  pointers**, across ticks (the design already mandates this — no object graph to
  translate, M3 §4.12).
- No `unordered_map` iteration in state-affecting paths (use sorted/`vector`),
  mirroring the GDScript "sort keys before iteration" rule.
- Avoid exceptions/RTTI/heavy templates in hot paths — "C with `std::vector`,"
  not modern-C++ acrobatics. A sim is one of C++'s *best-fit* workloads.

This is also an **ideal AI-coding task**: the GDScript sim is an executable spec,
the parity harness is a bit-exact oracle, and translation proceeds
function-by-function with immediate yes/no verification.

### 2.3 The boundary (recap, unchanged from design.md / M3 §4.12)

The boundary sits at the whole `src/sim/` module. Entity state (struct-of-arrays)
lives C++-side; GDScript crosses O(1) times per tick: `Sim.new(...)`,
`schedule(command)`, `step()`, `state_hash()`, plus batch read APIs for the view
(packed arrays of positions/fog/match-state per tick, not per-entity property
reads). The public sim surface is already shaped this way (M3 §4.11, M4 §15), so
the port changes the *implementation* behind that surface, not the surface.

### 2.4 The parity strategy and the GDScript sim's changed role

The verification is free and already paid for: the sim is *seed + commands →
hash stream*, so the port harness is **"run the GDScript sim and the C++ sim on
identical inputs, assert identical `state_hash()` every tick."** The determinism
suite becomes a bit-exact parity suite.

**But the GDScript sim's role changes, deliberately, to avoid writing everything
twice forever:**

- The GDScript sim **freezes at its M4 feature set.** It is the **parity oracle**
  (it proves the port is bit-exact for everything that existed at port time) and
  the **readable reference implementation** (kept in-repo, per design.md). It is
  **not** extended with new features.
- **C++ becomes the sole forward implementation.** New M5+ sim systems — the
  trigger VM first — are authored in C++ **once**.
- New systems are therefore verified by **determinism tests** (run the C++ sim
  twice from the same seed → identical hash), **not** cross-impl parity (there is
  only one impl). Determinism is fully testable with a single implementation;
  cross-impl parity was only ever about catching *translation* errors, which
  exist only for ported code. This is precisely the mechanism that delivers
  "don't write the VM twice."

### 2.5 Toolchain and CI

The one genuinely new infrastructure cost (design.md's "2–4 days of
godot-cpp/SCons/CI toolchain"):

- `godot-cpp` as a submodule; SCons (or CMake) build producing the native
  `.gdextension` library per target.
- **CI builds the native library for desktop Linux and Android** and runs the
  parity + determinism suites against the C++ build (the headless test scripts
  already exist; they now run against native too).
- Every contributor needs the native toolchain to build the sim — a real
  onboarding cost, noted. The GDScript reference sim keeps the project runnable/
  inspectable without it for non-sim work.

### 2.6 Port scope: the whole M4 sim (sized honestly)

The "~3–5 days mechanical translation" estimate in design.md predates the M3/M4
breadth — it was written at M2 against movement/combat alone. The real M5 port is
**all of `src/sim/`**: the substrate (`Fixed`, `DRng`, `ProcRng`, `SimGrid`,
`SimEntity`, command queue, `SimHash`), movement/collision/pathing (incl. lazy
theta\*), combat + damage classes, both economies, vision/fog + height-LOS,
structure lifecycle + capsule, stances/patrol, walls, elimination. Still
mechanical (all designed, tested, oracle-verified) — just scope it as the full
M4 system set, not the M2 core.

### 2.7 What stays GDScript permanently

Unchanged from design.md: everything outside the wall — view/interpolation, UI +
the catalog system, selection, camera, **the `TriggerCompiler` and the (future)
editor**, netcode session logic (ships commands, boundary-friendly), and all
*data* (catalogs, maps, the compiled trigger program). "UI as data" and "maps as
data" are unaffected. The trigger **compiler** is GDScript (it runs at load time,
human frequency); only the trigger **VM** is C++ (it runs every tick, inside the
wall).


## 3. The trigger system

The one new system inside the determinism wall, now authored directly in C++
(§2). design.md "Triggers and scripting" set the model — a tree of typed
event/condition/action nodes, executed by an interpreter inside the sim that can
only call the sim's command API. M5 builds it as an expressive, Lua-authored
language.

### 3.1 The mental model: triggers are compiled data, the VM is engine code

The reframe that dissolves "how does a C++ sim run JSON/Lua behavior": **a
trigger is never converted into native code.** The map ships *data* — a Lua
script compiled (outside the wall) to a flat, interned program. The **VM is
hand-written C++** that ships with the game and *reads* that program. This is the
identical relationship the catalog has with the sim: the compiler turns source
into interned ints, and the C++ sim reads the ints — it does not "compile the
map into C++." **Triggers are a more expressive catalog.**

Consequences:

- "How does behavior get into a bundle?" — as a Lua-flavored `triggers` source,
  compiled like the catalog (§3.9).
- "How does the C++ sim run it?" — it doesn't *convert* it; it *interprets* it.
  We write one VM. The map supplies a program. The VM walks it.
- "How is a stranger's map safe?" — the program is *data fed to our VM*, with a
  closed, audited action vocabulary (§3.4): no filesystem/network/reflection,
  Fixed-only arithmetic, `DRng`-only randomness, an op budget (§3.7). There is no
  general-purpose runtime to escape — only the specific actions we built (§3.8).

### 3.2 The VM: an expressive AST-walker in C++, inside the wall

**Inside the wall, in C++** (closes design.md Open Q #11 — §2.1). The compiled
trigger program is a flat, interned, typed tree (arrays of tagged int records, a
constant pool — *not* a pointer graph, so it is plain data the C++ sim owns).
Execution is a recursive walk: evaluate an expression node to a typed value,
execute a statement/action node for its effect.

**"AST-walker" and "fully expressive" are not in tension.** Tree-walking
interpreters handle locals, user-defined functions, recursion, and arbitrary
loops routinely — expressiveness lives in the *instruction set*, not in
bytecode-vs-AST. The M5 VM is expressive:

- **Locals and lexical scope** — a call/scope stack of activation frames; locals
  are frame-relative, hashed as live VM state (§3.6).
- **User-defined functions** — parameters, return values, recursion (bounded by
  the op budget and a call-depth cap, §3.7).
- **Arbitrary loops** — `while`/`for`, nested freely (op-budget-bounded).
- **Per-instance data — the MUI driver.** The single sharpest requirement on the
  IR: a periodic/timed effect must carry *its own* state per running instance, so
  **ten units running the same damage-over-time effect at once don't collide**.
  WC3 forced this through globals+arrays and hand-managed indices (the infamous
  "MUI" problem); we design it in from day one — a started timer/effect carries a
  typed instance record (locals captured at start), and its callback reads *that
  instance's* data. This is the concrete, testable proof the IR is actually
  expressive (exit criterion 4).

Bytecode lowering remains the documented perf escape hatch if per-tick-per-unit
triggers ever profile hot (the flat interned program is already
bytecode-adjacent); M5 ships the walker.

### 3.3 The registry: stdlib, typechecker, dispatch, future GUI

Every event, condition, and action/function the language can call is one entry in
a **node registry** — engine code/data, the single source of truth. Each entry
declares: id, category (event/condition/action/pure-function), typed parameter
slots (each a `TriggerType`, §3.6), return type, and its **C++ VM handler**. The
registry drives, from one definition:

1. **The compiler's typechecker** (§3.9) — unknown call = error, mismatched
   argument type = error (the M3 §2.3 discipline, now over a language).
2. **The C++ VM's dispatch** — node id → handler.
3. **A future GUI** — a graphical editor (deferred, §intro) would auto-generate
   its palette and parameter widgets from this same registry, which is *why*
   deferring the GUI costs us nothing structurally: the registry investment pays
   off for the compiler now and the editor later.

The registry is the language's **standard library**. It also dissolves WC3's
biggest GUI-vs-script gap by construction: there is no "function with no editor
button," because the (future) editor and the text language draw from the same
registry — they always have identical vocabulary.

### 3.4 Sim actions vs presentation actions (the hard split)

Trigger effects split, declared per registry entry:

- **Sim actions** — mutate sim state; run **in the C++ VM, inside the wall**,
  through the sim's existing mutation/command APIs, so their effects are hashed
  like everything else. Examples: create/remove unit, set/modify resource, set a
  unit field, reveal/hide fog, move/resize a region, enable/disable a trigger,
  set a variable, declare victory/defeat, **issue a `SimCommand`** (§3.5).
- **Presentation actions** — touch **no** sim state; the VM does not perform
  them. It appends a typed record to a per-tick **presentation event queue** the
  view drains after the tick — the seam M4's capsule-detection ping already uses
  (M4 §6.3). Examples: display message, ping minimap, play sound, screen fade,
  cinematic camera. These never enter the hash, so a cosmetic-only script can
  never desync a replay, and the cinematic still plays on each client.

The presentation queue is **derived output, never hashed** (like fog/aura
indices), read by the view via one batch call per tick. A sim action that also
wants a visible effect emits both: the mutation (hashed) and a presentation
record (not). This split is what lets triggers be cinematic without the headless
sim caring about screens.

### 3.5 The command-source unification

The sim's only mutating inputs are `SimCommand`s, now from three sources — the
human (UI), the bot (M4 §8), and **triggers**. A whole category of trigger
actions is *"issue order O to unit/group G"* — the same `SimCommand` path the
player and bot use, realizing M4 §8.4's "scenario AI = triggers issuing commands
to a computer player" directly (a wave script creates a squad for the AI player
and issues it an attack-move). On top of that, triggers get **privileged "god"
actions** a player cannot issue (free unit spawn, set-resource, runtime catalog
edits, reveal fog, end match). The trigger action vocabulary is thus a *superset*
of `SimCommand` plus the god set — designing that vocabulary *is* designing the
language (§3.10). Trigger-issued `SimCommand`s run normal validation; god actions
are separate, **trigger-origin-only** handlers, unreachable from the network
command stream.

### 3.6 Trigger state is hashed sim state

All mutable trigger state is in `state_hash()` (the M5 "forgot to hash a field"
canary, §8):

- **Global variables** — typed, interned to ids at compile. `TriggerType` ∈
  `int | fixed | bool | unit_ref | player_ref | region_ref | trigger_ref |
  unit_group | point | string_const | …`. Numbers are Fixed/int — **there is no
  float type** (the constitution, enforced by the language, §3.9). `unit_ref` is
  an entity id (stable, the iteration key); a ref to a dead entity reads null,
  checked by `is_alive`. Groups/arrays are id lists.
- **Call frames and locals** — the VM's activation stack while triggers run, and
  any suspended (`wait`-blocked) frame's saved locals (§3.7). Hashed so a pending
  `wait` survives replay bit-exactly.
- **Per-instance data** (§3.2) — the captured state of each running timed/periodic
  effect. Hashed.
- **Regions** — named map areas (pathing-cell rectangles/areas), loaded from the
  bundle and interned. Sim-relevant (events fire on them); a trigger action can
  move/resize one (hashed). "Move region" is one of design.md's own command-API
  examples.
- **Timers** and **trigger on/off flags** — tick-counted timers (never
  wall-clock); per-trigger enabled state. Hashed.

The VM holds no live engine object references across ticks (M3 §4.12) — refs are
ids, state is values — so it is exactly the value-and-array shape C++ wants.

### 3.7 The execution model

- **Event-driven, synchronous, in-tick.** The sim's tick order (M3 §4) gains a
  **`triggers`** phase. Sim systems record fired events into a per-tick list (the
  reap step records `unit_dies`; movement records `enters_region`; etc.); the
  trigger phase drains the list and runs matching triggers. Mutations land within
  the tick; precise phase placement (and whether downstream systems see mutations
  this tick or next) is a §10 detail to pin against the target maps.
- **Deterministic ordering.** Multiple triggers matching one event run in
  declaration order (ascending compiled index); one event firing for multiple
  entities runs ascending entity id. Same discipline as ascending-id iteration
  everywhere.
- **The op budget** — execution is capped at an **op count per tick** (node
  evaluations, not wall time, so peers advance identically — the exact mechanism
  the flow-field incremental build uses, design.md). Overrunning a per-trigger
  lifetime/call-depth bound kills the trigger with a diagnostic (a map-author
  bug, never a hang). Loops, function calls, and recursion all count against the
  budget — the `while(true)` and runaway-recursion defense.
- **`wait` is a tick-scheduled continuation, not a thread.** "Wait N seconds"
  suspends the trigger and schedules its resume at a future tick (the same
  mechanism as commands scheduled ahead), with the suspended frame's locals
  hashed. No coroutines, no engine timers, no peer-dependent resume order
  (concurrent resumes run ascending trigger index, §10).
- **Randomness** is `DRng` (or a trigger-scoped sub-stream seeded from it), never
  engine RNG — so "spawn a random unit" is replay-stable.

### 3.8 Determinism & safety summary

Safe and deterministic by construction, inheriting the constitution:

| Hazard | Mitigation |
|---|---|
| Native-code execution from a bundle | Impossible — triggers are data; only the engine's C++ VM runs (§3.1). |
| Desync across peers | VM is C++ sim code under the constitution; all trigger state hashed (§3.6); ordering deterministic (§3.7). |
| Infinite loop / runaway recursion | Op budget + call-depth/lifetime bounds (§3.7). |
| Float nondeterminism | No float type exists in the language; arithmetic is Fixed (§3.6, §3.9). |
| RNG nondeterminism | `DRng` only (§3.7). |
| Filesystem / network / reflection / FFI | No such function exists in the registry; no `loadstring`/`require`/stdlib beyond the registry — a closed, audited vocabulary (§3.4). |
| Illegal game action via trigger | Trigger `SimCommand`s run normal validation; god actions are trigger-origin-only (§3.5). |
| Tampered/oversized bundle | Content-hash mismatch → load failure (§4.1); field/size limits at compile (§3.9). |

The genuine attack surface — untrusted **asset parsing** — is **out of scope for
v1** (no custom assets, §1); when it returns with the map browser, it is the
thing to harden, not the triggers (§4.4).

### 3.9 The Lua-flavored language and its compiler

**Surface syntax is Lua-flavored** (decided): familiar to humans and the AI that
will largely author it, no significant-whitespace to parse, clean mapping to a
small typed language. It is **not Lua** — and the difference is documented as a
deliverable (below). The semantics are the constitution:

- **Numbers are Fixed.** No float type. Integer and Fixed literals; a bare
  decimal literal is Fixed; duration literals (e.g. `30s`) compile to ticks
  (the M3 `seconds`→ticks rule). A float-producing construct is a compile error.
- **Statically typed**, against the `TriggerType` set (§3.6) and the registry
  (§3.3) — every call and assignment is type-checked at compile.
- **Only registry functions are callable** — there is no ambient stdlib,
  no `string.*`, no metatables, no `pairs` over arbitrary tables, no `loadstring`.
  Collections are the typed ones the registry provides (`unit_group`, arrays).
- **Locals/functions/loops** as in §3.2; iteration order over groups is
  deterministic (ascending id).

`TriggerCompiler` (GDScript, `src/data/`, outside the wall, never ports):
lex → parse → typecheck against the registry → intern all names/strings to ints
(no strings reach the sim) → emit the **flat interned program** the C++ VM walks.
The compiler **hashes the compiled program, not the source** — comments and
whitespace can't affect determinism — and folds that hash into the initial state
(§4.1). String constants (for `display_message` etc.) live in the constant pool,
ride presentation records (§3.4), and are never in the sim hash, so localizing or
fixing a message can't desync a replay.

**Documentation is a first-class M5 deliverable.** Because the language wears
Lua's clothes but obeys different rules, the bet that AI (and humans) author it
reliably depends on a precise spec: the grammar, the type system, the full
registry/stdlib reference, and an explicit **"what is *not* Lua"** section (Fixed
numbers, no metatables/`string.*`/ambient stdlib, registry-only calls,
deterministic iteration, the op budget). This doc doubles as the system-prompt
context an AI needs to emit valid scripts and as the human reference. It ships
with the runtime, versioned alongside the registry.

### 3.10 Expressiveness and the staged standard library

The **architecture targets WC3-class power** (the registry is open-ended; reaching
parity is "add registry entries + C++ handlers," never a redesign), while the
**initial library is staged** against concrete target maps so it is grounded, not
guessed (the M3-style "ship a complete-feeling base, grow by demand" philosophy):

- **A tower defense** — periodic waves, region-following paths, leak counting,
  lives, win-on-survive. Exercises timers, `every_n_ticks`, region events, unit
  creation for an AI player, counters/comparisons, victory/defeat, message/ping.
- **A scripted-AI melee** — an AI ally/enemy that builds and attacks on a script,
  reinforcement waves, a scripted objective. Exercises issuing `SimCommand`s to a
  computer player (§3.5), `for_each_unit_in`, on/off trigger control, `unit_dies`.
- **A cinematic intro** — `match_start` → camera moves, transmissions, timed
  text, then control to the player. Exercises the presentation action set (§3.4)
  and `wait` (§3.7) end to end, proving the sim/presentation split.

The union of what these need is the M5 standard library, **enumerated as a first
pass in [trigger_vm_catalog.md](trigger_vm_catalog.md)** — the full menu of types,
language constructs, events, queries, actions, and presentation calls, each marked
sim-vs-presentation and M5-slice-vs-later, with a target-map coverage matrix that
derives the slice. Freezing that slice before implementation is §9 Q1. The MUI
requirement (§3.2) ensures the *language*, not just the library, is expressive
enough that a community could later build a custom spell or mechanic without us
shipping a new built-in.


## 4. The map bundle

### 4.1 What a bundle is

A folder (zipped for distribution), authored as text/JSON + Lua (no editor):

```
mymap/
  manifest.json     # name, author, version, players, game-mode, content hash
  terrain.json      # size, heightmap, blockers, biome/texture paint (v1: data only)
  objects.json      # placed units/structures/resources/start-locations/regions
  catalog/*.json    # override layers (M3 format) — the v1 "object editor" is this file
  triggers.lua      # the Lua-flavored trigger script (§3) — compiled at load
  assets/           # RESERVED, unused in v1 (custom assets out of scope, §1)
  ui/*.json         # optional UI override layer ("UI as data"), if a map customizes UI
```

- **The M3/M4 single-file maps still load** — `dev_arena.json` / `dev_clash.json`
  remain valid (the loader accepts a directory/zip or an inlined single JSON).
  The bundle is the superset.
- **Coordinates are pathing cells** (M3 §3); regions are pathing-cell areas (§3.6).
- **The manifest carries the content hash** of the compiled bundle (catalog + map
  + **compiled trigger program** + regions). On load it folds into the initial
  state hash (M3 §2.4 / §3): mismatched map data desyncs at tick 0 with a clear
  cause, never mid-match.

### 4.2 The load pipeline (extends M3 §2.4 / §3)

All outside the wall, emitting plain-int data the **C++** sim consumes:

1. `MapLoader` reads the manifest, resolves catalog layers, runs `CatalogCompiler`
   (unchanged) → `CompiledCatalog`.
2. Parse `terrain.json` + `objects.json` → spawn list + terrain grid + interned
   region table.
3. `TriggerCompiler` (§3.9) compiles `triggers.lua` → the flat interned program.
4. UI overrides ride the existing UI-catalog mechanism (M3 §6.7 / M4 §13.2).
5. All artifacts are int arrays/dicts; their SimHashes fold into the initial
   state. `Sim.new(seed, compiled_catalog, map_data, trigger_program)` — the
   trigger program joins construction as one more plain-data argument.

### 4.3 Terrain & objects as data (no editor in v1)

Terrain (size, heightmap, blockers, a v1 texture/biome paint layer) and objects
(units/structures/resources/start-locations/regions) are authored directly in
JSON. **Height already has sim meaning** — the height-LOS rule M4 §6.5 wrote
general consumes it — so an edited heightmap affects vision the moment the bundle
loads. Spatial authoring by hand/AI is workable for the test maps v1 needs; a
visual editor (the ergonomic win) is the deferred later milestone, and it will
read/write exactly these files, so nothing here is throwaway.

### 4.4 Custom assets — reserved, out of scope for v1

The bundle reserves `assets/`, but v1 ships **no custom-asset support**: maps run
on the M3 primitive-fallback views (distinct silhouettes/colors per entry). This
keeps the **one real attack surface — untrusted asset parsing on every device —
entirely out of v1** (§3.8). When custom assets return (with the map browser,
post-v1), they get the format allowlist, size/complexity limits, and importer
hardening that surface demands. Triggers, being data fed to our VM, were never
that surface.


## 5. Catalog overrides

The WC3 object-editor *capability* without the GUI: a map's `catalog/` layer
overrides any field of any entry and derives new entries via `extends`, using the
existing M3 merge (M3 §2.1–2.2) — later layers patch earlier ones per leaf key.
In v1 the override JSON **is** the editing surface (hand/AI-authored); the
`CatalogSchema` still validates it (unknown field, bad type, cycle, kind change =
error). A future object-editor GUI would be a form generated from `CatalogSchema`
— the same registry-driven dividend as the trigger palette (§3.3) — but it is
deferred. A custom unit with edited stats fights in a test match purely from the
override layer (exit criterion via the pillar-3 rebuild).


## 6. Cloud save (deferred)

design.md Open Q #9: cloud save + versioning is the first server-side dependency.
v1 is **offline-complete** — local bundle files, local undo/versioning if cheap —
and builds **no backend**. The content-hashed, self-contained bundle (§4.1) is
the seam a future sync layer ships whole; build-vs-buy/auth/offline-first stay
open, dated with M6's networking. Nothing in M5 assumes a server.


## 7. Tests

Per repo convention, one headless script per check in `tests/`, now runnable
against **both** the GDScript reference and the native C++ build:

- `port_parity_check.gd` — the whole M4 determinism suite as a **bit-exact
  parity** test: GDScript sim vs C++ sim on identical seed + command streams →
  identical `state_hash()` every tick, across economy/vision/walls/stances/bot/
  match scenarios. A single differing tick localizes the port bug.
- `native_build_check` (CI) — the native library builds for desktop Linux and
  **Android**, loads, and runs a smoke match; the M4 perf budget holds on a
  reference device profile (exit criterion 2).
- `trigger_compile_check.gd` — the Lua compiler: a valid script compiles and
  interns; an unknown function, a type-mismatched argument, a **float literal**,
  an undefined variable/region, and a cyclic call each fail with a clear error;
  the compiled-program hash is stable (golden); no strings reach the program.
- `trigger_runtime_check.gd` — the C++ VM, deterministic and exact: events fire
  in the right order (ascending entity id; declaration order across triggers);
  timers/`every_n_ticks` fire on the right ticks; `wait` suspends and resumes
  with restored locals; locals/scopes and a recursive user function evaluate
  correctly; `for_each_unit_in` iterates ascending id; on/off control works.
- `trigger_mui_check.gd` — **the expressiveness proof:** ten units running the
  same DoT effect simultaneously keep independent per-instance state and do not
  collide; exact damage/heal at fixed ticks.
- `trigger_command_check.gd` — a trigger creating units for a computer player and
  issuing them a `SimCommand` produces valid, normally-validated commands; god
  actions work from trigger origin and are unreachable from the network stream.
- `trigger_safety_check.gd` — a runaway script hits the op budget / depth cap and
  is contained without hanging or diverging; no float enters arithmetic; trigger
  RNG is `DRng`; presentation actions are present in the view queue and **absent
  from the hash**.
- `trigger_determinism_check.gd` (or folded into `determinism_check.gd`) — an
  M5 scenario (Lua-scripted waves + region objective + trigger-driven victory)
  twice from one seed → identical hash streams, covering all new hashed trigger
  state (globals, frames/locals, instance data, regions, timers, on/off flags,
  `wait` context).
- `bundle_loader_check.gd` — a full bundle round-trips (export `.zip` → import →
  content hash matches manifest); a tampered hash and an oversized field fail per
  §4.1; the M3/M4 single-file maps still load; the pillar-3 `dev_clash` rebuild
  compiles to content matching the hand-authored map (golden).
- `catalog_override_check.gd` — a map override layer derives a new entry and
  patches a field; the merged catalog compiles, hash stable; schema validation
  still fires on a bad override.
- `perf_check.gd` — extended and **re-baselined on the native build**: the
  150-unit/two-economy melee plus a tower-defense-style trigger load stays within
  the per-tick budget (the GDExtension tripwire is now the shipping floor).


## 8. Implementation order

Dependency-driven; each step lands with its tests green:

1. **Toolchain** (§2.5): `godot-cpp` submodule, native build, CI building desktop
   + Android, the existing headless tests running against native.
2. **Port the substrate** (§2.6): `Fixed`, `DRng`, `ProcRng`, `SimGrid`,
   `SimEntity`, command queue, `SimHash`. `port_parity_check` covers the
   substrate-level scenarios.
3. **Port the systems** (§2.6): movement/collision/pathing, combat/classes, both
   economies, vision/fog + height-LOS, structure lifecycle/capsule,
   stances/patrol, walls, elimination — function-by-function against the oracle.
   **`port_parity_check` fully green here — the C++ sim is bit-exact for M4.**
4. **Freeze the GDScript sim** as the oracle/reference (§2.4); C++ is now the
   forward implementation.
5. **The node registry + `TriggerType`s + trigger state** (§3.3, §3.6): the
   registry skeleton and the hashed VM state (globals/frames/locals/instance/
   regions/timers/flags), folded into `state_hash()`.
6. **The C++ VM** (§3.2, §3.7): the AST-walker, the `triggers` tick phase, event
   firing, locals/functions/loops/recursion, instance data, the op budget,
   tick-scheduled `wait`. `trigger_runtime_check` + `trigger_mui_check` +
   `trigger_safety_check` green.
7. **The Lua compiler** (§3.9): lex/parse/typecheck → interned program → bundle
   hash. `trigger_compile_check` green.
8. **The standard library** (§3.10): the slice derived from the three target maps,
   including the sim/presentation split (§3.4) and the command-source actions
   (§3.5). `trigger_command_check` green. **The trigger sim is feature-complete
   here**; `trigger_determinism_check` passes.
9. **The bundle format + loader** (§4): sections, regions, the `.zip` round-trip,
   `Sim.new(... , trigger_program)`. `bundle_loader_check` + `catalog_override_check`
   green.
10. **Language documentation** (§3.9): grammar, type system, registry reference,
    the "what is not Lua" section — shipped with the runtime.
11. **The pillar-3 rebuild + tower-defense map** (§1, §3.10): author both as
    bundles; the rebuild matches M4 (golden), the tower defense demonstrates the
    language end to end.
12. **On-device pass** — the milestone bar: the native sim runs a Lua-scripted
    match, deterministically, on an Android phone, loaded from a `.zip` bundle.


## 9. Open questions (need answers before or during M5)

Tracked here so they don't silently become decisions.

1. **Standard-library enumeration** (§3.10) — the precise event/condition/action/
   function list is the union of what the three target maps need, and must be
   *enumerated* (not just described) before step 8. Under-shoot forces a
   target-map redesign; over-shoot bloats M5. **First pass done** in
   [trigger_vm_catalog.md](trigger_vm_catalog.md) (menu + slice marks + coverage
   matrix); what remains is to *freeze* the slice — settle the `◐` (maybe-M5)
   entries into in-or-out — before implementation.
2. **Trigger phase placement and mutation visibility** (§3.7) — where the
   `triggers` phase sits in the tick, and whether mid-tick mutations are visible
   to downstream systems this tick or next. Confirm against the target maps.
3. **`wait` resume ordering** (§3.7) — the deterministic rule for multiple
   triggers resuming on the same tick (presumably ascending trigger index);
   confirm.
4. **Op-budget / call-depth tuning** (§3.7) — placeholder numbers; tune against
   the tower-defense target (the most trigger-heavy) so legitimate maps never hit
   the budget and runaway ones are caught fast.
5. **Port estimate vs reality** (§2.6) — the full-M4-sim port is larger than
   design.md's M2-era estimate; track actual effort to inform the M6 plan. Watch
   for any semantic gaps the parity harness surfaces (truncating division,
   shift behavior, iteration order) and document each fix.
6. **Android perf headroom** (§2/§7) — confirm the native build meets the budget
   on a real mid-range device early in the port, not at the end; if a hot loop
   resists, it is the first candidate for targeted optimization (the port's whole
   justification).
7. **Lua-subset friction** (§3.9) — how often AI/human authors reach for real-Lua
   features we lack (metatables, `string.*`, float math) and whether the compiler
   errors guide them back cleanly. A docs + error-message quality question, gauged
   during the target-map authoring.
8. **`build` of the GDScript test harness against native** (§7) — the headless
   test scripts must drive the native sim; confirm the GDScript test runner can
   load and exercise the GDExtension build in CI.

*Resolved during M5 design (folded into the body):* **no graphical world editor
in v1** — maps are JSON + Lua, parsed into levels; a GUI is a deferred later
milestone the registry-driven design keeps cheap (§intro, §4.3, §5); **the C++
GDExtension port moves into M5, before the trigger VM**, so the VM is written once
in C++ and gets the cleanest architecture (same-language, same-side, zero-crossing,
closing design.md Open Q #11) (§2.1, §3.2); **C++ via `godot-cpp`** — Rust's mobile
support is too experimental for a mobile-first project and Go's bindings are
unmaintained/ill-suited (§2.2); **the GDScript sim freezes as the parity oracle +
reference; C++ is the sole forward implementation**, new systems verified by
determinism (one impl) rather than cross-impl parity (§2.4); the **trigger VM is an
expressive AST-walker** (locals, user functions, recursion, loops, **per-instance
data / MUI**), with bytecode as a perf escape hatch (§3.2); the **language is
Lua-flavored but float-free, statically typed, and registry-bound**, compiled
(GDScript, outside the wall) to a flat interned program the C++ VM walks, with the
**compiled program (not source) hashed** and **language documentation a first-class
deliverable** (§3.9); **sim vs presentation actions are split** (§3.4); **triggers
are a command source** unifying scenario AI with the bot/player pipeline (§3.5);
**all trigger state is hashed** (§3.6); **safety is by construction** — closed
vocabulary, no runtime to escape, op budget, tick-scheduled `wait` (§3.7–3.8);
**custom assets are out of scope for v1**, keeping the one real attack surface out
entirely (§4.4); **cloud save defers to M6+** with the content-hashed bundle as the
sync seam (§6).
