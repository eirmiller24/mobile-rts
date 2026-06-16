# M3 Design — One Faction Playable

*Status: draft for review. Code does not start until this document is finalized.*

M3 per the [roadmap](../design.md): **Hive vs target dummies — strongholds,
capsules, nanomachine economy, 4–5 units, the Build and Economy console
tabs.** This document turns that one line into buildable specifications. It
extends [design.md](../design.md) and never contradicts it; where design.md
left a decision open, the decision is made here and flagged. All names and
numbers are placeholders unless stated otherwise.

What M0–M2 already give us: the gesture/selection/radial/console UI shell
instantiated from the UI catalog; a deterministic fixed-point sim with
movement, collision, pathing, combat, procs, command queue, and state
hashing. M3 is breadth on top of that: the object catalog, a map format,
economy/production sim systems, two real console tabs, and the first assets.


## 1. Scope

### In

1. **Object catalog** — data-driven definitions for units, structures,
   resource nodes, and abilities, with the WC3-style derive-and-override
   mechanism the M5 editor will ride.
2. **Test map format** — a hand-authored map file (subset of the M5 bundle
   design) with terrain size, resource nodes, start locations, and
   preplaced neutral dummies.
3. **Sim systems** — player resources and supply (Bandwidth), resource
   nodes, territory auras (influence), **fog of war** (sim-side vision), structure
   lifecycle (capsule → growing → complete), nanomachine economy, unit
   production, damage/armor classes, and the four base ability archetypes
   (passive aura, untargeted toggle, ground-targeted blink, build) proven
   end to end.
4. **Designations v1** — location and group designations, chips, the
   designation button. Scoped to what Build/Economy need.
5. **Minimap v1** — console-embedded, fog-aware, used by the Build flow.
6. **Build tab** — structure list from the catalog, placement via
   designation auto-resolve or the popup viewport.
7. **Economy tab** — per-stronghold nanomachine allocation sliders.
8. **HUD** — Alloy / Flux / Bandwidth readout.
9. **Assets** — placeholder-quality models and animations for the M3
   roster, plus the non-model view work (construction visuals, territory
   decal, fog overlay, placement ghost, capsule flight).

### Out (explicit deferrals)

| Deferred | To | Why |
|---|---|---|
| Rebels, workers, Crew supply | M4 | Per roadmap. (The Rebels' *extended-vision* identity is M4; fog of war itself is in — §4.4.) |
| Win/loss, bots | M4 | Per roadmap. |
| Strategy / Tactics / Organize / World tabs | M4+ | Build and Economy are the M3 tabs. *(Post-M3: Organize now hosts the control-group roster — see §6.1's note.)* |
| Drawn walls | M5 | No wall in the Hive M3 roster. The pathing-cell footprint substrate they need already exists. |
| Command queueing UI (waypoints, staged orders) | M4 (Strategy tab) | The sim's order queue already supports it (`queue` param); composing queues is console UI per design.md. |
| Audio | M7 art/sound pass | *Stretch for M3:* 2–3 placeholder order-acknowledgment chirps, because the "feedback without looking" thesis is testable cheaply. |
| Enemy targeting designations | M4+ | Tentative in design.md; nothing in M3 needs them. |

### Exit criteria

M3 is done when, on a phone:

1. A fresh game starts on the test map with one Stronghold and nothing else.
2. The Economy tab reallocates that stronghold's nanomachines; Alloy/Flux
   income accrues and deposits visibly deplete.
3. The Build tab places structures both inside influence (no capsule) and
   outside (capsule flies, lands, grows), via both placement paths
   (designation auto-resolve and popup viewport).
4. Fog of war behaves the Hive way: a capsule sent into fog lands and
   grows on free ground, is lost with no refund where a structure already
   stands, and hovers above blocking units until they clear (§4.5).
5. A Siphon on a Flux vent extracts Flux.
6. All four units train from the Stronghold, walk out, and fight the
   target dummies; Carapace root and Lancer burrow both work; Bandwidth
   gates training.
7. `determinism_check` passes with a scenario covering every new system;
   the desktop perf budget holds (sim tick ≤ 50 ms at ~150 units in combat
   *plus* a running economy).
8. Every button and tab still reads its meaning from catalog data — zero
   hardcoded bindings (CLAUDE.md rule, spot-checked in review).


## 2. The object catalog

The single most load-bearing piece of M3. Everything else — build menus,
training, the M5 object editor, map overrides — consumes it. Design goals,
in priority order: **deterministic** (catalog data feeds the sim),
**overridable** (WC3-style derive + per-field override, because M5 maps
patch it), **inspectable** (plain text, diffable, hand-authorable until the
editor exists).

### 2.1 Files and layers

JSON, consistent with the existing UI catalog (`data/ui/default_ui.json`):

```
data/catalog/core.json     # damage/armor classes, neutral entries (dummies, resource nodes)
data/catalog/hive.json     # Hive structures, units, abilities
data/catalog/rebels.json   # M4
```

A catalog is compiled from an ordered list of **layers**. For M3 the list
is `[core.json, hive.json]`, declared by the map (§3). In M5 a map bundle
appends its override layer to the same list — overriding rides load order,
not a special mechanism. Later layers may add new entries or patch existing
ones per-field.

The UI catalog stays a separate loader for M3 but its faction/map override
story (design.md "UI as Data") will reuse this same layer mechanism — noted
here so we don't accidentally diverge the two merge semantics.

### 2.2 Entry format and inheritance

Each file maps entry ids to entries. Ids are namespaced strings
(`hive.mite`, `core.alloy_deposit`). An entry:

```json
{
	"hive.mite": {
		"kind": "unit",
		"sim": { "...": "fields the simulation consumes" },
		"view": { "...": "model/animation/icon references" },
		"ui": { "label": "Mite", "description": "Cheap, fast melee swarmer." }
	},
	"hive.mite_veteran": {
		"extends": "hive.mite",
		"sim": { "hp": 60 }
	}
}
```

- **`kind`** ∈ `unit | structure | resource | ability | classes`. Fixed at
  the root of an `extends` chain; an entry cannot change kind.
- **`extends`** — single inheritance from any already-defined entry of the
  same kind (forward references within a layer are allowed; cycles are a
  compile error). Derived entries replace fields per leaf key. There is no
  field deletion — override with a neutral value (`0`, `""`) instead.
  This is the WC3 object editor model: new entries are cheap derivations.
- **Section split** — `sim` fields are the determinism boundary: typed,
  validated, hashed. `view`/`ui` fields are free-form and **not** part of
  the match hash, so a texture swap or typo fix in a label can never
  desync a replay. The M5 editor edits both through one UI; the compiler
  keeps the wall.

### 2.3 Field types and fixed-point authoring

The compiler validates `sim` sections against a schema table in code
(`CatalogSchema`): every field has a declared type, default, and range.
Unknown `sim` fields are a compile **error** (catches typos); `view`/`ui`
are open dictionaries.

Types:

| Type | Authored as | Compiled to |
|---|---|---|
| `int` | JSON number (integer) | int |
| `fixed` | **decimal string**, e.g. `"2.5"` | 16.16 `Fixed` int |
| `seconds` | decimal string, e.g. `"1.5"` | ticks (int, ×20) |
| `bool` | JSON bool | bool |
| `id` / `id list` | string(s) | interned `type_key` int(s) |
| `enum` | string | int (schema-declared set) |

**Why decimal strings for fixed:** JSON numbers arrive through a
string→float64 parse whose last-ulp behavior we'd be trusting across
x86/ARM and Godot versions, and "no floats in the sim" should include the
sim's *inputs*. Instead `Fixed.from_decimal(s)` parses digits directly
(integer + fractional part, scaled by 2^16, round-half-up) — never touches
a float, deterministic by construction, ~20 lines. A `seconds` value must
land on a whole tick (multiple of 0.05) or compile fails — silent rounding
of durations is how balance bugs hide.

### 2.4 Compilation and the sim boundary

`CatalogCompiler` (new, `src/data/`) does: load layers in order → merge →
resolve `extends` → validate against schema → intern ids → emit a
**CompiledCatalog**:

- `type_key` interning: all entry ids sorted lexicographically, index =
  key. Deterministic given the same layer content; entities store the int.
- Per-entry compiled `sim` blocks: plain Dictionaries, every value already
  int/Fixed/ticks. This — not the JSON — is what `Sim` receives at
  construction. The sim never reads a file and never sees a string stat.
- `view`/`ui` blocks kept alongside for the view layer, UI, and (M5)
  editor, addressable by the same keys.
- **Catalog hash**: SimHash (FNV-1a) over kinds, ids, and compiled `sim`
  blocks in key order. Folded into `Sim.state_hash()` as part of the
  initial seed value, so two peers with mismatched data files desync at
  tick 0 with an obvious cause instead of mid-game with a mystery.

### 2.5 Schemas

`sim` fields by kind. (Existing `DEFAULT_STATS` in sim.gd dissolves into
the catalog; `spawn_unit`/`spawn_structure` stat dictionaries are replaced
by `type_key` lookups.)

**`unit`**

| Field | Type | Notes |
|---|---|---|
| `hp`, `damage` | int | as today |
| `radius`, `speed`, `attack_range`, `acquire_range` | fixed | as today |
| `cooldown` | seconds | replaces `cooldown_ticks` |
| `crit_base`, `crit_bonus` | fixed | proc params, as today |
| `sight` | fixed | vision radius (§4.4); convention `acquire_range ≤ sight` |
| `hits_air` | bool | can attack airborne targets (capsules, §4.5); melee units author `false` |
| `attack_class`, `armor_class` | enum | from the `classes` entry (§2.6) |
| `bandwidth` | int | supply cost |
| `cost_alloy`, `cost_flux` | int | |
| `train_time` | seconds | |
| `abilities` | id list | ability entries; empty for most |

**`structure`**

| Field | Type | Notes |
|---|---|---|
| `hp` | int | full-grown value; growth ramps toward it (§4.5) |
| `foot_w`, `foot_h` | int | **pathing cells** (design.md: never assume tile-sized) |
| `armor_class` | enum | |
| `damage`, `attack_range`, `acquire_range`, `cooldown`, `attack_class`, `hits_air` | as unit | 0/absent = doesn't fight (Stronghold fights) |
| `cost_alloy`, `cost_flux` | int | |
| `build_time` | seconds | |
| `capsule_cost_alloy` | int | surcharge when built outside territory |
| `sight` | fixed | vision radius (§4.4); ≥ the structure's territory-aura radius so owned territory is never fogged |
| `damage_taken` | fixed | incoming-damage multiplier baseline. Hive structures author `"1.5"` — the feral state — and the influence aura restores `"1.0"` (§4.3) |
| `bandwidth_provided` | int | |
| `nano_pool` | int | strongholds only in M3 |
| `abilities` | id list | as unit; M3 structure abilities are auras (§4.3) |
| `trains` | id list | unit entries this structure can train |
| `builds_on_vent` | bool | Siphon placement rule (§4.2) |
| `requires_territory` | bool | can only be ordered inside own influence — never flies a capsule, the surcharge can't apply. The Siphon authors `true` (decided during M3 playtesting): extracting a far vent means extending influence to it first |
| `dummy` | bool | neutral target dummies: never acquires, never acts |

**`resource`** (map-placed nodes)

| Field | Type | Notes |
|---|---|---|
| `resource` | enum | `alloy` \| `flux` |
| `amount` | int | finite, depletes |
| `throughput` | fixed | max units/sec extractable from this node |
| `foot_w`, `foot_h` | int | pathing cells; blocks movement, untargetable |

**`ability`** — M3 ships **four** ability *kinds*, a deliberately
complete base of archetypes so the schema, command path, and UI are
load-tested from every direction at once: `aura` (passive area effect,
§4.3), `toggle_morph` (active, untargeted), `blink` (active,
ground-targeted), and `build` (macro — surfaced in the console, not on
the unit radial, §4.5). Together they are still not a generic effect
system — every field is schema-declared, same as everywhere else.

| Field | Type | Notes |
|---|---|---|
| `ability_kind` | enum | `aura` \| `toggle_morph` \| `blink` \| `build` |
| `morph_time` | seconds | toggle_morph: root/unroot duration (immobile, can't attack) |
| `morphed` | dict | toggle_morph: `sim`-typed stat overrides while morphed (Carapace root: `speed: "0"`, bigger `damage`/`attack_range`/`cooldown`) |
| `radius` | fixed | aura: effect radius from the owner's center |
| `affects` | enum | aura: M3 `own_structures` only (`own_units` etc. join when something needs them) |
| `flags` | string list | aura: marker flags granted to the covered *area*; the engine reads `territory` (§4.3, §4.5) |
| `modifiers` | dict | aura: schema-declared keys applied to affected entities — M3: `hp_regen` (fixed, hp/sec), `damage_taken` (fixed multiplier) |
| `range` | fixed | blink: max target distance from the cast position |
| `travel_time` | seconds | blink: time spent underground (untargetable, no collision) |
| `cooldown_time` | seconds | blink: per-entity cooldown, starts on surfacing |
| `structures` | id list | build: what this ability can construct — the Build tab reads this (§6.3) |
| `mechanic` | enum | build: `capsule` (M3 Hive — order from anywhere, no builder travel) \| `worker` (M4 Rebels — builder walks to the site) |

Auras are active only while their owner is functional (COMPLETE
structures, live units) and are evaluated statelessly (§4.3), so they add
no hashed state. When overlapping auras supply the same modifier key, the
value best for the affected entity wins (the schema declares per key
which direction is "best"); the same ability id never stacks with itself.
New ability kinds in later milestones extend this enum + schema; the M5
editor exposes whatever kinds exist.

**`classes`** — one singleton entry (`core.classes`) declaring
`attack_classes`, `armor_classes`, and the damage multiplier matrix
(fixed, authored as decimal strings). Compiled to a 2D array indexed by
interned class ints.

### 2.6 Damage and armor classes

Combat applies `damage × matrix[attack_class][armor_class]` (fixed mul,
truncating — document the rounding, it's sim-visible). Placeholder matrix:

| ↓attack \ armor→ | `light` | `armored` | `structure` |
|---|---|---|---|
| `claw` | 1.0 | 0.75 | 0.75 |
| `acid` | 0.75 | 1.5 | 1.25 |
| `shock` | 1.5 | 1.0 | 0.75 |

This is small, but it's the hook that makes "Spitter is good vs armor" a
catalog fact instead of code, and the M5 editor gets it for free.


## 3. The test map format

A deliberate subset of the M5 bundle (design.md "What a map is") — same
shape, fewer sections, so M5 extends rather than replaces it. One JSON
file for M3: `maps/dev_arena.json`.

```json
{
	"manifest": { "name": "Dev Arena", "version": 1, "players": 1 },
	"catalog_layers": ["res://data/catalog/core.json", "res://data/catalog/hive.json"],
	"terrain": { "tiles_w": 64, "tiles_h": 64 },
	"players": [ { "id": 1, "faction": "hive", "start_alloy": 500, "start_flux": 100 } ],
	"objects": [
		{ "type": "hive.stronghold", "player": 1, "cx": 12, "cy": 12, "completed": true },
		{ "type": "core.alloy_deposit", "cx": 20, "cy": 10 },
		{ "type": "core.flux_vent",     "cx": 8,  "cy": 24 },
		{ "type": "core.training_dummy", "player": 0, "cx": 80, "cy": 80 },
		{ "type": "core.thorn_turret",   "player": 0, "cx": 90, "cy": 84 }
	]
}
```

- Coordinates are pathing cells (consistent with footprints). Units may
  also be preplaced (`x`/`y` fixed-point world coords as decimal strings).
- Player 0 is reserved for neutral/hostile-neutral map objects.
- `terrain` is flat in M3; heightmap/biomes/cliffs are M5 sections that
  slot in beside `tiles_w/h` without breaking this format.
- A `MapLoader` (in `src/data/` with the catalog compiler) parses this,
  compiles the declared catalog layers, and produces the spawn list. Map
  content participates in determinism the same way the catalog does: a
  SimHash of the parsed map folds into the initial state hash.
- `Sim` construction becomes `Sim.new(seed, compiled_catalog, map_data)`;
  `main.gd`'s hardcoded demo spawns move into the map file.


## 4. Sim additions

Tick order grows from `commands → movement → combat → reap` to:

```
commands → economy → production → movement → combat → structures → reap → vision*
```

(`structures` = growth, regen, capsule landings; `vision*` = fog recompute,
every `VISION_PERIOD` ticks, §4.4. Order within each system is ascending
entity id, as everywhere. Every new field below is added to the relevant
`hash_into()` — that is a review checklist item, not a footnote.)

### 4.1 Players, resources, supply

New `SimPlayer` (plain object, like SimEntity): `id`, `faction` (interned),
`alloy`, `flux` — balances stored as **fixed** so fractional per-tick
income accrues exactly; the UI displays the floor. Created from map data,
hashed into `state_hash()` (ascending player id).

Bandwidth is *derived*, recomputed when queried: provided = Σ
`bandwidth_provided` over the player's COMPLETE structures; used = Σ
`bandwidth` over live units **plus queued trainees** (reserved at queue
time, §4.7). Derived-not-stored means it can never drift from the truth it
summarizes; it's cheap at M3 scale. Going over cap (stronghold dies)
strands units but blocks new training — the SC convention.

### 4.2 Resource nodes

Spawned from the map as entities with `kind = RESOURCE` (new SimEntity
kind): untargetable, block their footprint, never act, `amount` ticks
down as mined. Alloy deposits are mined directly by stronghold
nanomachines. **Flux vents** can't be mined; a Siphon must be built on
them. A structure with `builds_on_vent` has a special placement rule: its
footprint must exactly cover a vent's footprint (instead of requiring free
cells). The vent entity persists under the Siphon (it holds `amount`); the
Siphon stores `vent_id`. Siphon dies → vent is buildable again; vent
empties → Siphon stands but extracts nothing.

### 4.3 Territory auras (influence)

Influence is not an engine feature — it is an **aura ability** (§2.5)
that Hive buildings happen to carry. The Stronghold has `hive.influence`
(radius 12 tiles, flag `territory`, modifiers `hp_regen: "2.0"`,
`damage_taken: "1.0"`); the Relay has `hive.influence_relay`, derived
from it via `extends` with a smaller radius — the first real use of
catalog inheritance. The engine knows about *auras* and about the
`territory` flag; it does not know about strongholds. A custom map that
wants watchtowers projecting territory, or a healing aura on a unit,
writes catalog entries — no engine work.

Mechanics:

- An aura is active while its owner is functional (COMPLETE structure or
  live unit — a GROWING structure's abilities are off, §4.5). Coverage is
  a circle around the owner's *current* position: center-to-center
  distance ≤ `radius`. Owners can be mobile — a unit carrying an aura
  drags its circle with it; the engine makes no distinction between
  structure auras and unit auras.
- **The query primitive is per-aura, not per-feature.** The sim maintains
  an index of active aura sources — `player → ability id → [(owner id, x,
  y, radius)]` — rebuilt every tick in ascending owner id (derived data,
  never hashed, like buckets; per-tick rebuild is also what makes mobile
  owners free). Two query forms sit on it: `in_aura(player, ability, x,
  y)` for one specific aura, and `in_flagged_aura(player, flag, x, y)`
  for engine consumers keyed to a marker flag — each flag resolves to its
  set of granting ability ids at catalog compile time, so "in player P's
  territory" is just the flag form over `territory`. An arbitrary number
  of aura entries works without touching this code.
- **Stateless evaluation.** Nothing subscribes, nothing persists: every
  query computes from live state. Effective entity stats = catalog base +
  best covering-aura modifier per key (§2.5), found by scanning the aura
  ids whose `affects` matches the entity. O(sources) per query is nothing
  at M3 scale; if a map with hundreds of aura carriers ever shows up in
  profiles, the index grows spatial buckets — but not before.
- **The feral penalty is an inversion, and the inversion is what keeps
  this pure data**: a Hive structure's *base* `damage_taken` is `"1.5"`
  and its base regen is 0 — the weakened, non-regenerating state design.md
  describes is simply what a Hive structure *is*. The influence aura
  restores `damage_taken` to `"1.0"` and grants `hp_regen`. A structure
  goes feral when its stronghold dies and recovers when a Relay completes
  with no state transitions anywhere — the next evaluation just answers
  differently.

What reads the `territory` flag:

- **Build cost** (§4.5): inside own territory, no capsule — the structure
  starts GROWING immediately. Outside, `capsule_cost_alloy` is added and
  a capsule flies.
- **Nanomachine reach** (§4.6): a stronghold's mining/assist applies only
  within *its own* aura's circle (not the union) — allocation is
  per-stronghold, so its reach is too.

### 4.4 Vision and fog of war

Fog of war ships in M3, not M4 — the Hive's build-anywhere identity
*depends* on it. Building in ground you command is safe; building in
ground you merely see costs the capsule surcharge and an interceptable
flight; building in ground you can't see is a gamble that can lose the
capsule and everything paid for it (§4.5). Without fog the third tier
doesn't exist, and the Hive has no reason to control information and map
space like everyone else. Fog is sim-enforced per design.md — BUILD
validation reads it — which also keeps casual maphacks non-trivial later.

- **Per-player visibility map at build-tile resolution** (64×64 on the
  test map). A tile is visible if its center is within `sight`
  (center-to-center) of any of the player's live units or COMPLETE
  structures. GROWING structures and capsules project no sight — a nest
  dropped deep in fog grows blind, so the gamble keeps running until it
  finishes.
- **Derived data, never hashed** — like spatial buckets and flow caches,
  visibility is recomputed purely from hashed state (positions, sight
  stats) on a fixed cadence: every `VISION_PERIOD = 4` ticks. A tick-based
  cadence means every lockstep peer computes identical maps, so everything
  that reads visibility (BUILD validation §4.5, view, minimap) stays
  deterministic. Worst-case staleness is 200 ms — invisible at fog scale.
  Budget: ~150 units stamping ~150-tile sight discs every 4 ticks ≈ 6k
  cell writes/tick, well inside the M2 perf envelope; the cadence constant
  is the relief valve if profiling disagrees.
- **Two-state fog for M3**: terrain and resource nodes are always known —
  the map is public knowledge, which is what lets capsules target
  "anywhere the map allows" — and fogged tiles hide other players'
  *dynamic* entities (units, structures, capsules). No unexplored-black
  state and no last-seen structure memory yet; three-state fog is an M4
  conversation, where Rebel scouting makes it matter. The seam for adding
  it later is clean: memory is an additive per-player layer (a last-seen
  stamp per tile) on top of the same visibility map — nothing in M3 reads
  "explored", so no existing query changes. If memory stays presentation
  (ghost renders of last-seen structures) it isn't even sim work; it only
  enters the sim if some future rule consults it.
- **Combat is unchanged.** Acquisition already works on `acquire_range`;
  the catalog convention `acquire_range ≤ sight` (a compiler warning, not
  engine code) keeps units from fighting things their player can't see.
- Own entities always render regardless of sight — fog hides *others*,
  not your far-flung nests.

### 4.5 Structure lifecycle

Construction itself is an **ability** (kind `build`, §2.5), not an engine
special case. The M3 Hive's `hive.capsule_build` (mechanic `capsule`,
carried by the Stronghold) grants everything this section describes, and
its `structures` list is what the Build tab sells (§6.3). M4's Rebel
workers carry the same kind with `mechanic: worker` (the builder travels
to the site); a custom faction can put a build ability on anything. The
`capsule` mechanic's defining property is that it has no range and no
builder travel — order anywhere the map allows. A Hive player whose last
COMPLETE Stronghold dies can no longer build, and that is intended:
losing the last complete Stronghold *is* the Hive defeat condition when
win/loss arrives in M4, so there is no "after" to design for.

`build_state` ∈ `CAPSULE → GROWING → COMPLETE` (+ field `build_ticks_left`).

- **CAPSULE** (outside-territory builds only): the entity exists at the
  target location, airborne — does **not** block pathing, cannot act, and
  projects no sight. It is targetable but **aerial**: only attackers with
  `hits_air` can hit it (ranged attacks — melee can't bite the sky). Low
  hp; this is the Rebel counterplay surface in M4. No timeout and no
  recall — it flies, then hovers if it must, until it lands or dies.
  After `capsule_time` (global constant in `core.classes`, ~3 s) it tries
  to land:
  - Footprint holds a **static blocker** (structure, growing nest,
    resource node) → the capsule is destroyed and **nothing refunds**.
    The resources were the stake of building blind (§4.4); losing them is
    the rule, not an error case.
  - Footprint holds only **units** → the capsule **hovers**: it stays
    airborne (still targetable, still sightless) and retries every tick
    until the cells clear, then lands and starts GROWING.

  One landing rule everywhere — in vision the same situations are simply
  far less likely, because command-time validation (below) already saw
  the ground.
- **GROWING**: blocks its footprint, hp starts at 10% of max and ramps
  linearly with progress (attacking a half-built nest meets half the hp —
  the WC/SC convention, and what makes Rebel anti-construction units
  matter in M4). Cannot attack; its abilities (auras included),
  bandwidth, and nanos are all inactive. Progress is 1 tick/tick, plus
  assist nanos (§4.6).
- **COMPLETE**: full function. Transition fires exactly once (auras,
  bandwidth, etc. apply from the next query on).

Inside-territory builds skip CAPSULE and start at GROWING.

**BUILD validation is vision-gated** — this is where fog changes the
game. At execution the sim always checks the builder (`targets[0]` must
be a functional entity of the ordering player whose `build` ability lists
the structure type — for the M3 Hive, any COMPLETE Stronghold), the cost,
and the terrain (the map is public knowledge, §4.4). Occupancy is checked
only on footprint cells
**currently visible** to the ordering player: visible-and-blocked is a
silent no-op — commands are requests, the UI predicts validity, and a
stale prediction must not crash lockstep. Cells under fog are taken on
faith: the command proceeds, cost is deducted, the capsule flies, and
whatever actually stands there is discovered at landing. You can never
build on ground you can *see* is occupied; you can always *try* ground
you can't see. (Own territory is always visible — a structure's `sight`
covers its territory aura's radius — so the instant-GROWING path is
always fully validated.)

### 4.6 Nanomachine economy

Each stronghold has `nano_pool` nanomachines and an allocation across
three categories (ints, summing ≤ pool; the remainder idles):

- **`alloy`** — each tick, extraction = `alloy_rate` (global, fixed/sec
  per nano) × allocated nanos, drawn from alloy deposits inside this
  stronghold's own territory circle (§4.3) in ascending node id, each capped by its
  `throughput`. Drawn amounts decrement `amount` and credit the player.
  Allocation beyond what eligible deposits can supply idles (visible in
  the Economy tab so the player learns to rebalance — that feedback *is*
  the Economy tab's reason to exist).
- **`flux`** — same, but through COMPLETE Siphons inside the circle
  (ascending id), drawing from their linked vents.
- **`assist`** — each assist nano adds `assist_rate` bonus progress
  ticks/tick to GROWING structures inside the circle (ascending id, fill
  one then next), then repairs damaged COMPLETE structures (same order)
  at `repair_rate` hp/sec per nano. Construction before repair.

Allocation changes arrive as `ALLOCATE_ECONOMY` commands (§4.9). New
strongholds start with a catalog-declared `default_allocation` (decided:
everything on `alloy` for the Hive) so the game economically functions
before the player ever opens the console — important for first-touch
playtests.

Depletion: a node at `amount == 0` stays as scenery in M3 (still blocks).
Removing husks is a view/M5 polish question, not sim.

### 4.7 Production

`TRAIN` queues a unit at a structure whose `trains` list contains it.
Checks at execution: structure COMPLETE and owned, queue < 5, affordable,
bandwidth headroom ≥ unit's `bandwidth`. Cost and bandwidth reserve are
taken at queue time; `CANCEL` (by queue index) refunds both. One item
builds at a time (`ticks_left` on the head). On completion the unit spawns
at the first free cell found scanning rings outward from the footprint
(the `_surround_slots` ring-scan order, reused — deterministic); if no
cell is free, completion waits a tick and retries. If the structure has a
rally point, the new unit gets a MOVE order to it.

`SET_RALLY` sets/clears a structure's rally point (`rally_x/y`, fixed; 0,0
sentinel = unset).

### 4.8 Commanded abilities: root and burrow

One execution path for every commanded ability: an `ABILITY` command
names the ability (type_key) plus an optional ground target; per unit
(ascending id) the sim validates — ability in the unit's catalog list,
unit functional, cooldown elapsed, target within `range` for targeted
kinds — then dispatches on `ability_kind`:

- **`toggle_morph` (Carapace root)**: the unit enters the morph for
  `morph_time` (immobile, can't attack, orders cleared), then its stat
  overrides apply; toggling back mirrors it. No cooldown — the morph
  time is the cost.
- **`blink` (Lancer burrow)**: the unit goes underground — removed from
  collision and from enemy targeting/vision (its owner still sees it) —
  travels for `travel_time`, surfaces at the nearest free cell to the
  target point (the same deterministic ring scan production uses), and
  `cooldown_time` starts. Underground units occupy no cells and can't
  act. **Burrow is a pure teleport** (decided): walls, cliffs, crowds,
  and drawn barricades mean nothing underground; `range` and the cooldown
  are the counterweights. It cannot *surface* inside a blocked footprint
  — surfacing picks a free cell — only beyond it. If a burrow-proof
  barricade ever ships (an M5+ idea worth keeping), underground traversal
  becomes a queryable footprint property (`blocks_underground`) instead
  of an engine rule; nothing in the M3 shape blocks that.

Ability cooldowns are per-entity hashed state (`ability_cooldowns`,
ability key → ticks remaining, sorted-key iteration like procs). `build`
abilities don't run through this path — they validate inside BUILD
(§4.5) — and auras are passive (§4.3).

### 4.9 New and changed commands

`SimCommand.Kind` already reserves most of these:

| Kind | targets | params | Notes |
|---|---|---|---|
| `BUILD` | `[builder_id]` | `type` (type_key), `cx`, `cy` (pathing cells) | Builder must carry a `build` ability listing the type (§4.5); replaces the current debug footprint params. UI resolves *where* (designation auto-resolve or popup placement) and *who* before the command exists — the sim never sees "near Bravo". |
| `TRAIN` | `[structure_id]` | `type` (type_key) | |
| `CANCEL` | `[structure_id]` | `index` (queue slot) | New enum value. |
| `SET_RALLY` | `[structure_id]` | `x`, `y` (fixed) | New enum value. |
| `ALLOCATE_ECONOMY` | `[stronghold_id]` | `alloy`, `flux`, `assist` (int nanos) | Rejected (no-op) if the sum exceeds the pool. |
| `ABILITY` | `[unit_ids]` | `ability` (type_key); `x`, `y` (fixed) for ground-targeted kinds | Dispatches per `ability_kind` (§4.8). |
| `DEBUG_SPAWN` | — | `type`, position | Becomes catalog-driven; stat-dict spawning is removed. |

Command `params` carry only ints (type_keys, cells, fixed) — no strings on
the wire, which keeps M6 serialization trivial and hashing uniform.

### 4.10 SimEntity changes

New fields (all hashed): `type_key`; `sight`; `hits_air`;
`armor_class`/`attack_class` (interned ints); `damage_taken` (base
multiplier, §4.3); `build_state`, `build_ticks_left`; `rally_x/y`;
`train_queue` (array of `{type_key, ticks_left}`); `nano_alloc` (3 ints);
`amount` + `resource_kind` (resource nodes); `vent_id` (Siphon);
`morphed` + `morph_ticks_left` (Carapace); `underground_ticks_left` +
`surface_x/y` (Lancer); `ability_cooldowns` (sorted-key dict, §4.8).
`Kind` gains `RESOURCE`. Aura-granted modifiers are *not* entity state —
they are evaluated from the owner's catalog entry on demand (§4.3), so
there is nothing extra to hash.

One class keeps holding all kinds for M3 (it already mixes unit/structure
fields); if the field count gets silly we split per-kind during the C++
port, where struct-of-arrays forces the question anyway.

### 4.11 Sim public API

`Sim.new(seed, catalog: CompiledCatalog, map: MapData)`. New read-only
view accessors: per-player resources/bandwidth, structure build progress,
queue contents, allocation state, aura sources by ability id (the
territory decal reads these), and per-player fog bitmaps (one
`PackedByteArray` per call). All follow the M2 pattern of batch reads,
keeping the GDExtension boundary shape intact (design.md "The
GDExtension port").

### 4.12 What this means for the GDExtension port

Worth answering while the systems are still paper: how much of M3 gets
rewritten in C++ around M6? **Everything in §4, and nothing outside it.**
design.md already draws the port boundary at the whole `src/sim/` module,
and every M3 system above lives inside that wall on purpose — auras,
vision, economy, production, lifecycle, and abilities all read and write
entity state per tick, so leaving any one of them in GDScript would mean
crossing the boundary inside inner loops, which is exactly what the port
exists to kill. That includes the aura point query: its hot callers
(damage application, regen, economy eligibility, BUILD validation) are
sim-internal, so it ports with them — it is ~30 lines of circle tests
over the source index, mechanical to translate, and the parity harness
(identical hash streams from both implementations) verifies it like
everything else.

What M3 must honor *now* so that port stays mechanical — the
standalone-module discipline:

- **Inputs are plain data.** The compiled catalog and map are
  dictionaries/arrays of ints; no Resources, Nodes, or callables cross
  into the sim. (Already required by §2.4/§3 — this is the second reason
  why.)
- **Outputs are batch reads.** Every new view need gets a bulk getter
  (§4.11): fog as one `PackedByteArray` per player, aura sources and
  positions as packed arrays, economy as one dictionary per player.
  `PackedByteArray`/`PackedInt32Array` map 1:1 onto C++ buffers.
- **Point queries cross the boundary at human frequency only.** The
  placement ghost and Build-tab prediction may call the aura/visibility/
  footprint queries per gesture frame — one footprint at ~60 Hz while a
  finger is down is nothing. Rule of thumb: view crossings are O(1) per
  tick, UI crossings O(1) per active gesture; never a per-entity query
  loop outside the wall.
- **No retained references across ticks.** The aura index and vision maps
  are rebuilt from authoritative state each tick (no observer lists to
  translate), and cooldowns/queues are value state on entities. The C++
  translation is then structs and loops, not an object graph.

What never ports: the catalog compiler, map loader, UI catalog,
designations, minimap/console rendering, and the view — they live on the
far side of the boundary and already speak plain data.


## 5. The M3 Hive roster

Numbers are tuning placeholders; the *shape* (who's cheap, who needs Flux,
who has the ability) is the design. Costs in Alloy/Flux, times in seconds.

| Entry | Cost | Time | BW | Role |
|---|---|---|---|---|
| **Stronghold** | 400/0 | 45 | +20 | `hive.influence` aura (r=12 tiles, §4.3), 60 nanos, trains all units, basic attack (15 dmg, shock). 1500 hp. |
| **Relay** | 100/0 | 15 | +8 | `hive.influence_relay` aura (r=6, derived via `extends`), no nanos, no attack. 300 hp. Capsule surcharge 75. |
| **Siphon** | 150/0 | 20 | 0 | Builds on Flux vents only. 400 hp. |
| **Mite** | 25/0 | 8 | 1 | Fast melee swarmer. 40 hp, 5 dmg claw, light. |
| **Spitter** | 60/0 | 12 | 2 | Fragile ranged acid — good vs armor/structures. 50 hp, 9 dmg acid, light. |
| **Lancer** | 75/25 | 16 | 2 | Mid-tier shock melee with **Burrow** (ground-targeted blink, §4.8: range 8 tiles, 1.5 s underground, 10 s cooldown). 90 hp, 14 dmg shock, armored. |
| **Carapace** | 100/50 | 24 | 3 | Slow tank; **root** morphs it into a turret (range 4, 25 dmg, immobile; 1.5 s morph each way). 180 hp, armored. |

Sight placeholders (tiles): Stronghold 14 (covers its r=12 influence),
Relay 8 (covers r=6), Siphon 6, melee units 7, Spitter 8 (ranged units
see at least as far as they acquire). Air targeting: the capsule is the
only airborne thing in M3; `hits_air` is true for the Spitter, the
Stronghold's attack, the rooted Carapace, and the thorn turret — claws
stay grounded. Stronghold capsule surcharge: 150 (expanding by capsule
should sting but be the faction's signature move). Neutral entries in `core.json`:
**training_dummy** (500 hp structure, armored, no attack) and
**thorn_turret** (350 hp structure, attacks 10 dmg claw, acquire 7) — one
passive and one hostile dummy so combat is testable in both directions.
Resource nodes: **alloy_deposit** (1500, throughput 2.0/s, 2×2 cells),
**flux_vent** (1000, throughput 1.0/s, 4×4 cells).

Sovereign node stays a design sketch — nothing in M3 references it.


## 6. UI work

### 6.1 Designations v1

The architectural call first: **designations are not sim state.** They are
player-local handles — naming a group or a spot changes nothing in the
world, and lockstep peers never need to agree on them. They live in the UI
layer (`src/ui/designations.gd`), and every console flow that uses one
resolves it to explicit entity ids / coordinates *before* a SimCommand is
created. (M4's "tactics persist on the designation" stays UI-side too: the
designation re-issues SET_TACTIC commands to members. Nothing here forces
sim awareness later.)

M3 scope, per design.md's proposed mechanics:

- **Group designations**: designation button tap with selection → next
  free slot; flick to pick a slot. Tap with no selection → radial of
  existing designations → select that group / jump to that point.
- **Location designations**: long-press ground → "designate" popup.
- **Chips**: up to 8 along the top edge; tap selects/centers. Chips get
  auto-names (Alpha, Bravo… for groups; numbered pins for locations) —
  renaming is the Organize tab's job (deferred).
- Dead units silently drop from groups; empty groups free their slot.

This is M1-style engine-layer mechanics work (the radial idiom already
exists); chip *styling* hooks into the UI catalog like every other widget.

> **Superseded (post-M3 rework).** The designation button's assign/recall
> radial didn't survive playtesting — four petals capped groups at four and
> made selection editing impossible. It was replaced by the **control
> button** (design.md "The control button"): a held modifier that adds/removes
> from the selection, queues orders, toggles a unit type, and overwrites a group
> via its chip. Its radial has two petals — swipe up to make a new group from
> the selection, swipe down to deselect all. Group *creation* also lives on the
> Organize tab's "New control group" button (`group_roster` widget); both
> creation paths make an empty group when nothing is selected. Recall stays on
> the chips, which now read raw touch (so a chip tap registers as the second
> finger while the control button is held — plain Buttons only see the primary
> touch under mouse emulation).
> The corner **reselect button** was removed (its auto-deselect / reselect-last
> logic kept dormant in `SelectionController`). Sim order queues
> (`Sim._order_move`'s `queue` flag) back the new viewport queueing.

### 6.2 Minimap v1

Console-embedded only (the Build flow per design.md; no corner minimap is
specced anywhere). A `MinimapView` widget: top-down low-res render —
ground, blocked terrain, resource nodes by type (always drawn, §4.4),
influence tint, designation pins, entity dots by faction on visible tiles
only, fog dimming elsewhere. Redraws at ~4 Hz from sim reads, plus
immediately on open. Input modes: *jump* (tap → center main camera there,
close console — the design.md "select a minimap location" path) and *pick*
(tap → return a map position to the requesting flow, used by Build).

### 6.3 Build tab

Screen 1 — **structure grid**: one button per buildable structure
(catalog-driven: the union of `structures` across the player's functional
`build` abilities — for the M3 Hive, the Stronghold's
`hive.capsule_build` (§4.5) — with costs, dimmed when unaffordable).
Tapping one arms a placement flow. Screen 2 — **placement**: the minimap
in pick mode with the player's location-designation pins highlighted:

- **Tap a designation pin → auto-resolve**: client-side spiral search from
  the pin for the first legal footprint (inside-influence cells preferred,
  then any); issues `BUILD` with explicit cells. The player never leaves
  the console. Legality is judged on what the player can see — fogged
  cells count as free, and the sim settles the truth at landing (§4.5).
- **Tap "place precisely" (or any bare map point) → popup viewport**
  (§6.4) jumped there for hand placement.
- Either path shows the capsule surcharge before confirming when the spot
  is outside influence, and a distinct "unseen ground — capsule at risk"
  warning when any footprint cell is fogged. Cost surprises are how trust
  dies; the fog gamble must always be an *informed* bet.

Siphons skip placement search: the pick step lists/highlights known vents.

### 6.4 Popup viewport

The design.md mechanic, built in M3 because Build needs it: a SubViewport
with **its own camera** over the console — the main camera never moves, so
closing the console restores exactly the prior view. M3 uses it for
structure placement: ghost footprint mesh snapped to cells, green/red
validity tint (client-side prediction of the same vision-gated checks the
sim runs; amber when the footprint overlaps fog — placeable, at your own
risk), drag to move, confirm/cancel buttons (placement commits on *confirm*, not
on tap — fingers are imprecise). The widget is generic (camera + content
callback) since Strategy/Organize reuse it in M4+.

### 6.5 Train screen (Build tab, screen 3)

Design.md doesn't pin training UI down, so: a **unit grid** alongside the
structure grid (catalog `trains` lists, costs, bandwidth). Tap a unit →
TRAIN at the eligible structure with the shortest queue (lowest id
tie-break — but the *UI* picks it; the command carries the explicit
structure id). Long-press → choose the structure via chips. A queue strip
shows per-structure queues with tap-to-cancel. Console-first training is
the commander fantasy; selecting a stronghold in the viewport to train
from it is M4 polish if playtests miss it.

### 6.6 Economy tab

One row per stronghold (designation chip name + location thumbnail):
three sliders — Alloy / Flux / Assist — sharing the nano pool (a slider
pushed past the remaining pool steals from idle first, then proportionally
from the others — never silently fails), plus an idle-nanos indicator and
live income numbers (and "allocation idle: no deposits in range" warnings,
§4.6). Sliders quantize to whole nanos and emit `ALLOCATE_ECONOMY` **on
release**, not per drag-frame — commands are lockstep traffic.

### 6.7 HUD and catalog extensions

Top-edge readout: Alloy, Flux, Bandwidth used/max (catalog-skinnable
labels/icons — Bandwidth is Hive-specific naming, M4's Crew reuses the
slot). The UI catalog gains widget types: `structure_grid`, `unit_grid`,
`alloc_sliders`, `minimap`, `queue_strip` — each an engine-coded widget
*parameterized by data* (which catalog kinds it lists, filters, which
screen it links to), consistent with the UI-as-data split: mechanics in
code, meaning in `default_ui.json`. The M3 `default_ui.json` replaces the
current dummy Build/Economy screens with real definitions.

The M1 ability side button also gets its first real content: its radial
slots populate from the selection's catalog `abilities`. Root is
untargeted (fires on the selection immediately, like stop); burrow is
targeted (arms the verb, then tap the ground) — both are the existing M1
command grammar with data-supplied verbs, no new interaction mechanics.

One UI-as-data dividend to implement deliberately: the Hive has no Mine
context order (no workers) — `context_orders.resource` in the *Hive*
UI data maps to `move`. The mechanic ships in M4 with the Rebels; the
binding is already just data.


## 7. View layer and assets

### 7.1 Conventions

- Scale: 1 Godot unit = 1 build tile = `Fixed.ONE` (matches main.gd's
  existing mapping; sim y → world z).
- Pipeline: Blender 4.2 → glTF into `assets/models/<faction>/<entry>.glb`.
  The catalog `view` block references model path + AnimationPlayer clip
  names: `idle`, `walk`, `attack`, `death` (units); `grow`, `idle`,
  `attack` (structures); Carapace adds `root`, `rooted_idle`,
  `rooted_attack`, `unroot`.
- View code reads everything through the catalog — `unit_view.gd`'s
  hardcoded capsule/box becomes the *fallback* for entries without a model,
  which is also the placeholder strategy: every entry works as a colored
  primitive first, models land incrementally without code changes.

### 7.2 Asset list (the actual lift)

Models (low-poly, flat-shaded, silhouette-first per design.md art
direction): Stronghold, Relay, Siphon, capsule (+ simple flight arc),
nest/growth stage (one generic "growing mass" mesh reused by all
structures at <100% progress, scaled/blended by progress — buys us out of
per-structure growth models), Mite, Spitter, Lancer, Carapace (+ rooted
form), training dummy, thorn turret, alloy deposit, flux vent. ~14 meshes,
~20 short animation clips. Hive read: iridescent black/green, skitter and
pulse.

### 7.3 Non-model view work

Fog-of-war presentation (dimmed ground outside vision; other players'
units and structures hidden under fog — two-state, no last-seen memory in
M3, §4.4); territory ground decal (driven by the sim's aura-source reads,
faction-tinted, updates as strongholds/relays complete or die);
construction progress presentation
(growth mesh + progress ring); placement ghost (§6.4); capsule flight,
hover bob, and landing puff;
health bars on damaged entities (first time we need them — selected +
damaged only, thumbnail-size readability); resource node depletion tint;
floating "+income" ticks are *out* (noise on a phone).


## 8. Tests

Per repo convention, one headless script per check in `tests/`, runnable
locally and in CI (the 4.6.3 binary download path already exists):

- `catalog_check.gd` — schema validation errors fire (bad field, bad type,
  cycle, kind change, off-tick seconds, unknown aura modifier key);
  `extends` merge correctness (the relay aura deriving from
  `hive.influence` is the live test case);
  `Fixed.from_decimal` exactness (golden values incl. rounding); compiled
  catalog hash is stable (golden hash — catches accidental schema drift).
- `economy_check.gd` — scripted scenario: allocate, mine to depletion,
  build inside/outside influence, fogged build lost with no refund on an
  occupied site, capsule hover over units then landing, visible-blocked
  BUILD no-ops, siphon+vent, train with bandwidth blocking, cancel
  refunds, carapace root, lancer burrow (range/cooldown/surfacing), and
  capsule air-targeting (melee can't hit it, `hits_air` can). Asserts exact balances/hp/progress at fixed
  ticks (catalog placeholders make these golden numbers).
- `determinism_check.gd` — extended: the M3 scenario (economy + builds
  into fog + train + combat vs dummies) run twice from the same seed →
  identical hash streams, with vision recompute ticks covered. This is the canary for "forgot to hash a new field."
- `perf_check.gd` — extended: the 150-unit melee now runs alongside a
  ticking economy (3 strongholds, 12 structures, queues full) to keep the
  measurement honest against the §1 exit criterion.
- `ui_catalog_check.gd` — extended for the new widget types and the real
  Build/Economy screen definitions.


## 9. Implementation order

Dependency-driven; each step lands with its tests green:

1. `Fixed.from_decimal`; catalog schema + compiler + `catalog_check`.
2. Map format + loader; `Sim.new(seed, catalog, map)`; main.gd demo spawns
   move into `dev_arena.json`. (Existing checks keep passing — this is the
   refactor step.)
3. Sim: players/resources/bandwidth; resource nodes; aura evaluation +
   territory queries (§4.3); vision/fog (§4.4).
4. Sim: structure lifecycle + capsule + BUILD; nanomachine economy +
   ALLOCATE_ECONOMY.
5. Sim: TRAIN/CANCEL/SET_RALLY; ABILITY runtime (toggle_morph + blink,
   §4.8); damage classes.
   `economy_check` + determinism extension complete here — **the sim is
   done before any UI work starts.**
6. Designations v1 + chips.
7. Minimap widget; popup viewport widget.
8. Build tab (3 screens); Economy tab; HUD readout; UI catalog data.
9. View: catalog-driven entity views with primitive fallbacks; territory
   decal; construction/capsule presentation; health bars.
10. Asset production (parallel to 6–9, lands incrementally).
11. On-device playtest pass — the milestone bar is "playable on a phone."


## 10. Open questions (need answers before or during M3)

Tracked here so they don't silently become decisions (answers fold back
into this doc).

*Implementation notes (M3 build, 2026-06-12).* Small deviations made
during implementation, none load-bearing:

- **Assets**: per project decision, M3 shipped on catalog-driven
  primitive views only (step 10 deferred); the `view` block pipeline is
  in place, so models land without code changes. No audio (stretch goal
  skipped).
- **Long-press designate** (§6.1) acts directly (pin + haptic) instead of
  opening a one-option popup menu.
- **Designation radial** used the 4-petal idiom, so flick-assign and
  radial recall reached slots 1–4; slots 5–8 were reachable via chips.
  *Superseded by the control-button rework (see §6.1's note): the radial is
  gone, group creation moved to the Organize tab, and recall is chip-only.*
- **Train screen** (§6.5): shortest-queue auto-pick shipped; the
  long-press structure chooser is deferred with the rest of Organize.
- **Capsule flight** renders as a vertical descent + hover bob over the
  site, not an arc from the builder.
- **Globals**: a separate `flux_rate` joined `alloy_rate` in
  `core.classes` (the doc's "same" read as same *mechanism*).
- **World tab** got a jump-mode minimap as a freebie (the tab itself
  remains M4+).
- The catalog gained a structure field `default_allocation`
  (idle/alloy/flux/assist) to implement §4.6's catalog-declared default.
- *Post-playtest (2026-06-12):* structures gained `requires_territory`
  (§2.5) and the Siphon authors it — siphons can only be built inside
  influence, so expanding to a far vent means walking territory out to
  it (relay chain or capsule stronghold) first. BUILD rejects
  requires_territory orders outside influence before charging; the
  placement UI shows "needs influence" and the pin auto-resolve only
  considers influenced vents. Placement also gained vent *snapping*: a
  vent-bound ghost within ~5 world units of a vent magnetizes onto it
  (fingers don't have 4-cell accuracy).

*Resolved 2026-06-12 and folded into the body:* capsule hover has no
timeout and no recall, killable only by `hits_air` attackers (§4.5);
two-state fog for M3 with a clean seam for last-seen memory later (§4.4);
both Carapace root *and* Lancer burrow ship, giving all four ability
archetypes (§2.5, §4.8); default allocation is all-alloy (§4.6); 8
designation chips (§6.1); auto-resolve prefers inside-territory cells
(§6.3); all numbers stay placeholder until the step-11 tuning pass;
losing the last COMPLETE Stronghold ends building by design — it is also
the Hive defeat condition when win/loss arrives in M4 (§4.5); burrow is a
pure teleport, drawn barricades included, with a burrow-proof barricade
noted as an M5+ idea (§4.8).

Nothing is currently open. New questions land here as they come up.
