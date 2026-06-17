# M4 Design — Two Factions + Bots

*Status: draft for review. Code does not start until this document is finalized.*

M4 per the [roadmap](../design.md): **Two factions + bots — Rebel roster,
supply, a competent scripted bot, win/loss. First full game loop.** This
document turns that one line into buildable specifications. It extends
[design.md](../design.md) and [design_m3.md](design_m3.md), and never
contradicts them; where they left a decision open, the decision is made
here and flagged. All names and numbers are placeholders unless stated
otherwise.

What M0–M3 already give us: the gesture/selection/radial/console UI shell
instantiated from the UI catalog; a deterministic fixed-point sim with
movement, collision, pathing, combat, procs, command queue, and state
hashing; the object catalog (derive-and-override) and a map loader; the
Hive faction end to end — territory auras, fog of war, the
capsule build mechanic, nanomachine economy, production, the four ability
archetypes (`aura`/`toggle_morph`/`blink`/`build`), and the Build/Economy
console tabs. M3 left two of M4's biggest hooks already in the schema and
the command enum: `BuildMechanic.WORKER` (defined, unhandled) and the
`SET_TACTIC`/`PATROL` command kinds (declared, unhandled).

M4 is the milestone that turns a sandbox into a **game**: a second faction
that plays by genuinely different rules, an opponent to play against, and a
reason for the match to end. It is mostly *breadth* on the M3 sim plus one
new economy shape (worker harvesting) and one new system class outside the
sim wall (the bot).


## 1. Scope

### In

1. **The Rebels faction** — HQ, workers, Crew supply (housing), and a
   combat roster (Gunner, Watcher, Demolisher, Marauder bike), built as a
   second catalog layer (`data/catalog/rebels.json`). No new sim mechanics
   the schema can't already express, with the exceptions below.
2. **Worker harvest economy** — the SC/WC gather loop: a worker walks to a
   resource source (Alloy deposit, raw Flux vent, or a vent-pooling
   **Refinery**), fills its carry, returns to the HQ depot, deposits, repeats;
   driven by the Economy tab's **intent dials** rather than per-unit babysit
   (§3). This is the Rebels' economy, the mirror of Hive nanomachines, and the
   one genuinely new sim system in M4.
3. **The worker build mechanic** — `BuildMechanic.WORKER` made real: the
   builder travels to the site and occupies itself constructing, the
   counterpart to the Hive's order-from-anywhere capsule (§4) — and its
   extension, **drawn walls**, where a finger stroke becomes a queue of
   Barricade segments workers raise in order (§4.4, pulled forward from M5).
4. **Crew supply** — the second supply pool. Mechanically it is the M3
   supply system already in place; M4 supplies the Rebel data and the
   faction-labeled HUD (§5). Cheap by design — the slot was reserved in M3.
5. **Rebel vision identity** — three-state fog (unexplored / explored /
   visible) and last-seen structure memory, **capsule detection** (the
   Watcher's anti-capsule warning), **knowledge-gated order resolution**
   (orders act on what you see/remember, not on fog ground truth — fixing an
   M3 leak, §6.4), and **walls that block ground vision** (Barricades stand
   tall and occlude line of sight — the seed of the height-based high-ground
   LOS; flyers see over them, §6.5). Information warfare is the Rebel pillar;
   this is what makes it real (§6).
6. **Win/loss and the match loop** — a data-driven elimination condition,
   match-over detection, and a Quick Match flow: pick factions, spawn two
   players on a 1v1 map, play to a victory/defeat result screen (§7).
7. **The scripted bot** — a competent macro AI built as a *command source*
   outside the sim wall, issuing the same `SimCommand`s a human issues
   (design.md: "a bot is a command source"). This both gives M4 an opponent
   and load-tests the command API for completeness (§8).
8. **Unit AI v1 — stances and the Tactics tab** — `SET_TACTIC` made real:
   stances (defensive / balanced / reckless / skirmish) and a small set of
   priority flags that the movement and combat systems honor, attached to
   designations so reinforcements inherit them. `PATROL` made a real
   back-and-forth order (§9).
9. **UI work** — the Tactics tab; the Rebel UI catalog layer (faction skin
   + the real Mine context order + Crew HUD label); a victory/defeat
   result screen and a minimal match-setup screen (§13).
10. **View and assets** — the Rebel roster as catalog-driven primitives
    first, models landing incrementally; three-state fog and last-seen
    ghost rendering; worker carry/harvest visuals (§14).

### Out (explicit deferrals)

| Deferred | To | Why |
|---|---|---|
| **Full Strategy tab** (raid / escort / maintained multi-group standing orders) | M7 | Roadmap puts "strategy/tactics tabs full version" in M7. M4 ships the *sim primitives* a competent bot and the Tactics tab need (stances, hold-at-point, patrol); the rich composed standing orders are M7. (§10) |
| **Worker garrison** ("workers can garrison to defend") | M7 | design.md lists it; it's a transport/load mechanic with no other M4 dependency. The Rebel defensive identity in M4 comes from vision + anti-construction, not garrison. |
| **Broker** (Rebel support caster — bribes/jamming/smoke) | M5+ | design.md marks it TBD; its dirty-tricks abilities need ability kinds M4 doesn't ship. The four M3 archetypes cover the rest of the roster. |
| **Networked / lockstep bot** (bot on the wire, host owns the slot) | M6 | M4 runs on one machine; the bot runs locally as a command source. The wire/ownership rules are an M6 concern, flagged in §8. |
| **Three-state fog memory consulted by *sim* logic** | — (may never) | M4 keeps explored-state and last-seen ghosts in the *view* (§6) — no sim rule reads them, so they stay presentation, exactly the seam M3 §4.4 left. |
| **Editor, replays UI, ranked/match­making** | M5 / M6 / later | Per roadmap. Replays are still *free* (seed + command stream) and used as the bug-report format; no UI yet. |
| **Audio** | M7 | *Stretch for M4:* the Watcher capsule-detection ping is the one event whose "feedback without looking" value is high enough to prototype a chirp for. |

### Exit criteria

M4 is done when, on a phone:

1. A Quick Match starts on a 1v1 map: a human Hive (or Rebel) player and a
   bot opponent of the other faction, each with a start base and nothing
   borrowed from the other's rules.
2. **Rebels play the Rebel way:** workers harvest Alloy by hand into the HQ,
   take Flux slowly by mining a vent directly or fast through a vent-pooling
   Refinery; the Economy tab's intent dials (worker target, alloy/flux and
   build/mine ratios, auto-repair) keep the fleet on task and auto-replace
   losses; structures are raised by a worker that walks to the site, and a
   drawn stroke raises a Barricade wall segment by segment; Crew caps the
   army; vision is extended around units and structures.
3. **The Hive still plays the Hive way** — every M3 behavior intact, proven
   by the M3 tests still passing.
4. A Rebel Demolisher kills a Hive capsule/nest under construction
   noticeably faster than a Gunner (anti-construction bonus), and a Watcher
   pings an incoming Hive capsule through fog.
5. **The bot is a real opponent:** left alone it expands, builds an army,
   attacks, and defends competently enough that a new player can lose to
   it; it issues only ordinary `SimCommand`s; killing its last producer
   ends the match.
6. **The match ends:** eliminating the opponent's production (the
   data-driven defeat condition, §7) fires a victory/defeat screen; the
   loser's surviving units stop mattering; a rematch is one tap.
7. Stances change behavior observably: a defensive group holds its ground
   and a reckless group chases; the Tactics tab sets them and
   reinforcements inherit them.
8. `determinism_check` passes with an M4 scenario (two factions, worker
   economy, a recorded bot command stream, a match played to elimination)
   run twice from the same seed → identical hash streams; the desktop perf
   budget holds (sim tick ≤ 50 ms at ~150 units in combat with two running
   economies). **Tripwire watch:** if bot matches drop ticks on desktop at
   the army sizes we field, the GDExtension port pulls forward to post-M4
   (design.md "The GDExtension port").
9. Every button, tab, HUD label, and context order still reads its meaning
   from catalog data — the Rebel UI is a *data layer*, zero hardcoded
   bindings (CLAUDE.md rule, spot-checked in review).


## 2. The Rebels

Faction identity (design.md): *see everything, hit hard, punish the Hive
for every inch it tries to take.* Where the Hive is everywhere, cheap, and
feral outside its territory, the Rebels are grounded, expensive, durable,
and informed. The asymmetry is mechanical, not cosmetic, and M4 is where we
prove the catalog can express "a faction that works completely differently"
without engine special cases — the editor's hardest promise.

The three mechanical pillars of the difference:

- **Workers, not nanomachines.** Economy is *embodied* — units that walk,
  carry, and can be killed (§3). Harassing a Rebel mineral line is a real
  play; harassing a Hive's is not (there's nothing there but a stronghold).
- **Build by walking, not by capsule.** Structures need a worker on site
  (§4). The Rebels cannot teleport a base across the map; they expand by
  escorting a worker and holding ground.
- **Information as defense.** Extended sight, three-state fog they actually
  exploit, and capsule detection (§6). The Rebels turn map knowledge into
  efficient, pre-positioned defense — the counter to "the Hive is
  everywhere."

### 2.1 The M4 Rebel roster

Numbers are tuning placeholders; the *shape* is the design. Costs in
Alloy/Flux, times in seconds, supply is Crew.

| Entry | Cost | Time | Crew | Role |
|---|---|---|---|---|
| **Headquarters** | 450/0 | 50 | +10 (provides) | Main structure. Trains Workers, is the resource **depot** (`is_depot`) for **both Alloy and Flux**, basic attack. ~1600 hp. Authors a healthy starting Crew (`bandwidth_provided ~10`, placeholder) so a fresh base can field an opening force — a handful of workers and a unit or two — before the first Housing goes up. |
| **Housing** | 100/0 | 18 | +10 (provides) | Crew-supply structure (the Rebel "depot/relay" of supply). No attack, no nanos. ~350 hp. |
| **Refinery** | 150/0 | 22 | 0 | **Standalone** Flux processor: auto-links every Flux vent within `refinery_radius` and lets workers harvest refined Flux from it at the full rate (§3). A *source, not a depot* — refined Flux is hauled to the HQ. ~450 hp. |
| **Worker** | 50/0 | 14 | 1 | Harvests Alloy/Flux, **builds structures** (`build`, mechanic `worker`), repairs. `carry_capacity`, `harvest_rate`. ~60 hp, weak claw. |
| **Gunner** | 75/0 | 12 | 2 | Starting infantry; solid all-rounder. **Bonus vs unfinished structures** (§4.3). ~110 hp, shock. |
| **Watcher** | 60/0 | 14 | 1 | Cheap sensor; long `sight`, **`detects_capsules`** (§6.3). Fragile, light. Effectively a mobile early-warning. ~70 hp. |
| **Demolisher** | 130/25 | 22 | 3 | Anti-structure specialist; heavy bonus vs structures (esp. unfinished). The capsule/expansion killer. Slow, armored. ~160 hp, acid. |
| **Marauder bike** | 90/0 | 16 | 2 | Fast harasser for hunting relays and outlying nests. Fragile, high speed. ~80 hp, shock. |

Sight placeholders (tiles, Rebels see further than Hive per identity): HQ
16, Housing 8, Refinery 7, Worker 8, Gunner 9, Watcher 16 (+capsule
detection), Demolisher 8, Marauder 11. Air targeting (`hits_air`): Gunner,
Watcher, and Demolisher true — the Rebel answer to capsules is to arm the
crews that hunt construction so they can also swat a capsule out of the air,
the **Demolisher** above all (the dedicated capsule-killer). The **Marauder
bike is ground-only** (`hits_air: false`), and so is the Worker: the bike is
a fast ground harasser for relays and outlying nests, not an interceptor. So
"anti-air" is a deliberate **per-unit data fact**, not a blanket faction
trait — a Rebel commander who *knows* the Hive ships bases as capsules equips
the right units for it, and the catalog lets the roster say exactly that.

The **Broker** stays a design sketch (deferred, §1). The Rebels do **not**
have the feral-structure penalty (no `damage_taken: "1.5"` base, no
territory aura) — Rebel structures are simply durable everywhere. That
absence is itself the asymmetry: the Hive trades reach for fragility
outside territory; the Rebels have no territory mechanic and pay for it in
mobility.

### 2.2 New neutral / shared catalog

`core.json` gains nothing structural; the existing `core.alloy_deposit`,
`core.flux_vent`, `training_dummy`, and `thorn_turret` are reused. Both
factions mine the same two resource node types — the *method* differs, not
the nodes. New 1v1 maps preplace mirrored resources (§7.4).


## 3. The worker harvest economy

The one genuinely new sim system in M4. The Hive's economy is allocation of
a disembodied pool (M3 §4.6); the Rebels' is a loop of physical bodies that
move, carry, deposit, and die. It must be deterministic, fixed-point, and
fold into the hash like everything in `src/sim/`.

### 3.1 The harvest loop

A worker (a unit with `carry_capacity > 0`) runs a small state machine,
stored as hashed entity fields. `harvest_state` ∈
`IDLE → TO_SOURCE → HARVESTING → TO_DEPOT → DEPOSITING → (back to TO_SOURCE)`:

- **TO_SOURCE** — the worker paths to its assigned source — an **Alloy
  deposit**, a **Flux vent** (direct mining, slow), or a **COMPLETE Refinery**
  (refined Flux, fast) — using a **surround slot** on the source's perimeter
  (the existing `_surround_slots` ring assignment, reused — so a crowd of
  workers spreads around a source instead of piling on one cell).
- **HARVESTING** — within reach of the source, the worker accrues
  `carry` at `harvest_rate` (fixed, units/sec) up to `carry_capacity`,
  decrementing the source node's `amount` (capped by the node's
  `throughput`, shared across all workers on that node in ascending worker
  id — the same cap discipline Hive mining already uses). A worker mining a
  depleted node (`amount == 0`) goes IDLE.
- **TO_DEPOT** — full (or source-empty with carry), the worker paths to the
  **nearest COMPLETE `is_depot` structure of its own player** — in M4 that is
  the **HQ**, the only depot, taking both Alloy and refined Flux — nearest by
  path-agnostic distance, ties by lowest id (deterministic).
- **DEPOSITING** — at the depot, `carry` transfers to the player's
  resource balance (fixed, accrues exactly; UI floors it), then the worker
  returns to TO_SOURCE for the same source.

`carry` is `(resource_kind, amount)`; both hashed. A worker carrying alloy
when re-tasked to flux drops nothing (carry is fungible on deposit — it
deposits what it holds, then switches). Worker death mid-carry loses the
carried amount (it was never banked) — harassing a worker line is real.

**Two ways to get Flux.** Unlike the Hive (which *must* build a Siphon on
each vent to extract Flux into its nano pool), the Rebels can take Flux two
ways, a free floor and a paid boost:

- **Direct vent mining (free, slow, light loads).** A worker `MINE`-ordered
  onto a Flux vent harvests it directly — no structure required — accruing
  `carry` at the slow `raw_flux_rate` (a global fraction of `harvest_rate`)
  and only up to `raw_flux_carry` (a global cap *below* the worker's full
  `carry_capacity`), capped by the vent's `throughput`, drawing down its
  `amount`, then hauling to the HQ. This is the Rebel Flux floor: they are
  never *locked out* of Flux the way a Hive denied its Siphon is, but
  hand-mining raw vents is slow and the loads are small.
- **The Refinery (fast, pooled, full loads).** A standalone **Refinery**
  built near a Flux cluster **auto-links every Flux vent whose center is
  within `refinery_radius`** of it (resolved once at COMPLETE into a hashed
  `linked_vents` id list, ascending vent id; vents don't move). It holds **no
  stored Flux** in M4 — a worker accessing the Refinery draws *live* from the
  linked vents, the Refinery just being a faster, higher-capacity tap onto
  them. So a worker assigned to Flux harvests *at the Refinery* at the full
  `harvest_rate` **and fills to its full `carry_capacity`** (vs the throttled
  rate and small `raw_flux_carry` of a raw vent), and the Refinery draws the
  extracted amount down across its linked vents (ascending id, each capped by
  its own `throughput`, the pooled cap shared across all workers on the
  Refinery in ascending worker id — the same discipline as a shared node).
  Two levers make it worth the haul: **higher extraction rate and bigger
  loads per trip**, so the round trip to the HQ amortizes over far more Flux.
  One Refinery concentrates a whole vent cluster into a single source and
  **costs one building for the cluster** where the Hive pays a Siphon per
  vent. A Refinery whose every linked vent is depleted stands inert.
  (Letting it *buffer* Flux — so workers top up instantly and expansion
  caching matters — is a clean later addition, §18; M4 keeps it a pass-through.)

The Refinery is a **source, not a depot** (M4 decision): refined Flux still
rides a worker back to the HQ, so a Refinery placed out among distant vents
trades a longer haul for its extraction boost — a real placement decision,
and the reason to keep building HQs/forward bases as you expand. (Whether the
Refinery should *also* bank Flux as a forward depot is the obvious
convenience knob; left as a playtest question, §18, to keep the M4 harvest
loop one-depot-simple.)

### 3.2 The Economy tab as worker intent (macro layer)

design.md: for the Rebels the Economy tab is "assigning worker counts per
resource and approving auto-replacement of lost workers." M4 refines that
into a small set of **intent dials** the player sets and the sim
continuously approximates — the Rebel analog of the Hive's nano sliders, and,
like nano allocation, **sim-side** so the approximation runs identically on
every lockstep peer. The player sets a target *distribution*, not a roster;
"whatever is the closest approximation of what you asked for" is the sim's
job, every tick.

Per player, the Economy tab authors four values (a `SET_ECONOMY` command,
§12, emitted on slider release):

- **`worker_target`** (int) — desired total worker headcount. The sim trains
  toward it and **auto-replaces losses**: whenever live+queued workers fall
  below the target, the lowest-id HQ with queue headroom queues a Worker,
  paying Alloy and Crew at queue time (the normal TRAIN reservation, M3
  §4.7), skipping silently when unaffordable or Crew-capped. This is the "set
  it and forget it" promise — a raided mineral line refills itself. (No
  spending guardrail; we trust the dial — §18.)
- **`alloy_flux_ratio`** (fixed 0..1) — how the *harvesting* pool splits
  between Alloy and Flux.
- **`build_mine_ratio`** (fixed 0..1) — how the *whole* pool splits between a
  **build/repair reserve** and the harvesting pool.
- **`auto_repair`** (bool) — whether idle build-reserve workers seek the
  nearest damaged own structure and repair it (§4.2).

Each economy tick (ascending player id) the sim turns the dials into target
counts and reconciles actual tasks toward them:

1. From the live worker count and `build_mine_ratio`, compute the **build
   reserve** size; the remainder is the **harvest pool**, split by
   `alloy_flux_ratio` into desired Alloy and Flux harvester counts (round
   half-up — deterministic).
2. Reassign the **nearest free** workers (idle first, then over-supplied
   categories, taking the highest-id worker so assignment is stable; ties by
   id) until actual counts match desired — workers flow between Alloy
   sources, Flux sources (Refineries preferred over raw vents when both are
   in range, §3.1), and the build reserve. A worker mid-carry finishes its
   deposit before being reassigned (it never drops banked-but-uncarried
   resource — §3.1).
3. The build reserve waits available near base; when a `BUILD` / `REPAIR` /
   wall order (§4) needs a builder it is drawn from this reserve —
   **nearest reserve worker first**, then, if the reserve is empty, the
   nearest harvester (and `build_mine_ratio` ticks up to reflect that the
   player asked for more building than the dial reserved). **This is the
   answer to "where does the builder come from": the build/mine dial *is* the
   pre-committed builder pool, and an explicit order overdraws it gracefully
   rather than stalling construction.**

**Manual orders adjust the dials, they don't fight them.** Unlike the Hive
(where a manually-ordered unit is *pinned* out of macro), a Rebel worker has
no per-unit pin — the dials are the whole truth, so a hand order **feeds back
into the intent** instead of escaping it:

- Manually `MINE`-ordering workers onto Alloy or Flux nudges
  `alloy_flux_ratio` toward that resource by the ordered workers' share (and
  biases node selection toward the tapped node while it lasts).
- Manually ordering a `BUILD` / `REPAIR` / wall nudges `build_mine_ratio` up
  enough to cover the builders it consumes.

So the viewport and the tab are the same control at two altitudes: tapping
individual workers *is* editing the sliders, by hand and locally. (How far a
one-off manual order should move a dial — and whether the dial relaxes back
when the task ends — is a feel question for the tuning pass, §18.) Keeping
the whole thing dial-driven is what lets auto-replace and reconcile stay
**sim-side and identical on every peer**, while the tab crosses the boundary
only at human frequency (one `SET_ECONOMY` on slider release).

### 3.3 Why this stays inside the sim wall

The harvest loop reads and writes entity state every tick (positions,
carry, source amounts, balances) — it is squarely inside `src/sim/` and
ports to C++ with everything else (design.md "The GDExtension port"; M3
§4.12). The dial reconcile is O(workers) per economy tick, trivial at
M4 scale, and touches only value state (no retained references), so it
translates mechanically. The Economy tab crosses the boundary at human
frequency (one `SET_ECONOMY` on slider release), not per worker.


## 4. The worker build mechanic

`BuildMechanic.WORKER` was defined in the M3 schema and left unhandled.
M4 implements it as the counterpart to `capsule`. design.md: "Workers set
up buildings"; the build ability's defining property here is the inverse of
the capsule's — it has **range and builder travel**.

### 4.1 BUILD with `mechanic: worker`

The Rebel Worker carries `rebels.worker_build` (kind `build`, mechanic
`worker`, `structures: [headquarters, housing, refinery, ...]`). A `BUILD`
command names a worker as `targets[0]` (the M3 path already validates that
the builder carries a `build` ability listing the type). The mechanic
branch differs:

- **No capsule, no surcharge, no fog gamble.** A worker build has no
  airborne stage and no `capsule_cost_alloy`. Validation is the M3 build
  validation (vision-gated occupancy, cost, terrain) *minus* the
  capsule-into-fog allowance: a worker can only be *ordered* to ground the
  player can legally reach and place on. (The Rebels build where they can
  walk; the Hive gambles into fog. That's the asymmetry.)
- **The worker travels.** On a valid order, the structure does **not**
  start GROWING immediately; the worker receives an internal move to the
  footprint perimeter (surround slot). The structure is reserved but
  unstarted (a new build-state nuance below).
- **On arrival, GROWING begins** and the worker enters a `BUILDING` state:
  immobile at the site, not harvesting, not fighting, contributing
  `build_rate` progress per tick. Pulling the worker off (any new order)
  **pauses** construction; the structure holds at its current progress
  (GROWING, no auto-progress) until a worker resumes it.
- **Multiple workers accelerate, for a price (the WC3 model, decided).**
  Up to `max_builders` (global, placeholder ~3) workers may `BUILDING` one
  site; each adds `build_rate` progress, so construction finishes faster the
  more bodies you commit. The *first* builder's progress is free (the
  structure's cost already paid for it); **each additional builder drains
  resources while it assists** — `accel_cost_rate` (global, fixed Alloy/sec
  per extra builder), deducted per tick from the owner and stopping the
  instant the player can't pay (the extra worker idles at the site,
  contributing nothing until funds return). So speed is buyable with
  workers *and* resources together, and a player racing a building up pays
  for the rush — exactly WC3's repair-to-accelerate. Order within a site is
  ascending worker id (deterministic); the per-tick drain is one
  fixed-point subtraction folded into the economy hash like every balance.
- Cost is taken at **order** time (reserved like TRAIN), refunded if the
  order is cancelled before GROWING begins; once GROWING, cancel destroys
  the structure for a partial refund (placeholder 50%) — the SC convention.

`build_state` gains the worker nuance without a new enum value: a
worker-built structure spawns directly in `GROWING` with
`build_ticks_left = build_time` and a flag `needs_builder` (true until a
worker is on site). `needs_builder && no worker present` ⇒ progress frozen.
The Hive's instant-GROWING path is `needs_builder = false`. One field,
both factions, no special-case system.

### 4.2 Repair

Workers also repair (design.md). A worker ordered onto a damaged own
COMPLETE structure (a `REPAIR` order, or the build order's natural
extension) restores hp at `repair_rate` for an Alloy trickle. M4 scope:
**repair piggybacks on the build path** — a worker on a damaged COMPLETE
structure enters `BUILDING` and heals it instead of progressing
construction; the Hive's nano `assist` already repairs (M3 §4.6), so this
is the Rebel mirror, not a new system. (Standalone repair-cost tuning is a
balance lever, numbers placeholder.)

### 4.3 Anti-construction bonus

design.md: Rebel units are "especially effective at destroying structures
while being built" — the counter to capsule rushes. This is a **damage
class fact**, not engine code, exactly like M3 §2.6. Two pieces:

- A new armor class `construction` that GROWING/CAPSULE structures present
  *instead of* their normal `armor_class` while not COMPLETE. The combat
  system already reads `armor_class`; it reads `construction` for
  not-yet-complete structures (one branch in damage application).
- The matrix gives anti-construction units a high multiplier vs
  `construction`: Demolisher `acid` and Gunner `shock` get bonus rows; Hive
  units get ordinary values. So "Demolisher melts capsules" is a number in
  `core.classes`, and the M5 editor gets it for free.

Placeholder matrix additions (extends the M3 table with the new column):

| ↓attack \ armor→ | `light` | `armored` | `structure` | `construction` |
|---|---|---|---|---|
| `claw` | 1.0 | 0.75 | 0.75 | 0.75 |
| `acid` | 0.75 | 1.5 | 1.25 | **2.5** |
| `shock` | 1.5 | 1.0 | 0.75 | **1.75** |

(The capsule's *aerial* targeting rule from M3 §4.5 still applies — only
`hits_air` units reach a flying capsule at all; the construction multiplier
governs what happens once they can hit it, and on the landed GROWING nest.)

### 4.4 Drawn walls (Rebel barricades)

design.md makes **drawn walls** a touch-native exception to tile-snapped
construction (a finger stroke rasterized into a chain of pathing-cell
segments), and the M3 doc deferred them to M5 *only because the Hive has no
wall*. The Rebels do — barricades around a base are the physical half of the
Rebel defensive identity (information is the other half, §6) — and walls ride
the worker-build mechanic this section already builds, so M4 **pulls drawn
walls forward from M5** rather than inventing a parallel system. This is the
one roadmap move M4 makes; flagged here and in §18. The pathing-cell footprint
substrate they need already exists (design.md; M3 §2.5 — footprints are stored
in pathing cells, nothing assumes tile-sized).

A **Barricade** is an ordinary Rebel `structure` with a **1×1 pathing-cell**
footprint (the finer grid): own hp, attackable, blocks pathing, **stands ~2
levels tall so it blocks ground line of sight** (`los_height`, §6.5 — the
second half of why the Rebels wall up), dies independently — so an attacker
chews a hole through a wall rather than dropping it whole. It is built by the worker-build mechanic (§4.1)
like any structure. What is new is **how a line of them is ordered and
constructed**:

- **The draw gesture (UI).** A "build wall" verb (Build tab) arms a modal
  stroke; the player drags a line and it rasterizes — integer-grid supercover,
  the same deterministic LOS primitive pathing already uses — into an
  **ordered list of segment cells** running from the stroke's start. The UI
  emits one **`BUILD_WALL`** command carrying that ordered cell list.
  Pricing-per-cell, min/max stroke length, and how the modal stroke coexists
  with the lasso gesture are design.md Open Q #10 — flagged, not solved (§18).
- **The build plan (sim).** `BUILD_WALL` installs a per-player **wall plan**:
  an ordered queue of pending segment cells. A pending segment is *not yet a
  structure* — it blocks nothing and costs nothing until work begins on it —
  so a half-drawn or half-built plan never walls the player in prematurely.
  The worker-build system pulls segments off the head of the queue in stroke
  order and assigns build-reserve workers (§3.2): a worker walks to the next
  pending cell, the segment spawns `GROWING` (`needs_builder`, §4.1) and is
  **charged then** (per-segment Alloy, at start-of-construction), the worker
  raises it, then advances to the next pending cell. Multiple workers drain
  the queue in parallel, each claiming the next unclaimed segment (ascending
  cell order, ascending worker id — deterministic).
- **Cancel leaves the built portion.** Cancelling the wall (`CANCEL` on the
  plan) clears the *remaining* queue; segments already built or `GROWING`
  persist as the independent structures they are, and nothing pending was
  ever charged — so a stroke cancelled halfway leaves exactly the wall you
  paid for, with no refund math. To turn a corner, draw a **new** `BUILD_WALL`
  stroke starting where the last ended; two strokes make an L. This is
  precisely the "draw, cancel, redraw in a new direction" loop design.md's
  commander wants.

The wall plan is hashed per-player state (the pending-cell queue + which
segments are claimed), folded into `state_hash()` like every order. Walls add
no new *combat* or *pathing* rule — a Barricade is just a small structure on
cells the footprint substrate already addresses — only the **segment-queue
construction order** is new, and it lives entirely inside the worker-build
system.


## 5. Crew supply

The cheapest "system" in M4, because M3 already built it. The supply
mechanic — provided = Σ `bandwidth_provided` over COMPLETE structures, used
= Σ `bandwidth` over live units + queued trainees, over-cap blocks new
training (M3 §4.1, `bandwidth_of`) — is faction-agnostic already. Crew is
that mechanic with Rebel data and a Rebel label:

- **Data:** the Rebel **Housing** structure authors `bandwidth_provided`
  (Crew capacity); Rebel units author `bandwidth` (Crew cost). Numbers
  differ from the Hive (units cost more Crew and are stronger, design.md),
  but no field or code is new.
- **Label:** the HUD's supply readout label is UI-catalog data (M3 §6.7
  reserved the slot: "Bandwidth is Hive-specific naming, M4's Crew reuses
  the slot"). The Rebel UI layer (§13.2) sets the label to "Crew" and its
  icon; the engine never knows the word.

No schema change, no sim change. We *do* rename nothing — the sim field
stays `bandwidth`/`bandwidth_provided` (the generic supply slot); only the
displayed string is data. This is the "UI as data" dividend paying out
exactly as designed: a second supply identity for the cost of a catalog
layer. (If a future faction wants a *mechanically* different supply — e.g.
a soft cap with overflow penalties — that becomes a new schema field then,
not now.)


## 6. Rebel vision identity

design.md's Rebel pillar is information. M3 shipped two-state fog and
explicitly left three-state fog and last-seen memory as "an M4
conversation, where Rebel scouting makes it matter" (M3 §4.4), with a clean
additive seam. M4 has that conversation.

### 6.1 Three-state fog (presentation)

Fog gains a third state: **unexplored** (never seen — solid black),
**explored** (seen before, not currently — dimmed, terrain known),
**visible** (in current sight — bright, live entities shown). Per M3's
seam, "explored" is **cumulative** and is **not consulted by any sim rule**
(BUILD validation reads *current* visibility, never memory), so it stays in
the **view layer**: the fog overlay accumulates an `explored` bitmask by
OR-ing the sim's per-tick per-player visibility bitmaps (already exposed,
M3 §4.11). The sim is untouched; this is pure presentation, exactly as M3
predicted ("if memory stays presentation it isn't even sim work").

### 6.2 Last-seen structure memory (presentation)

When an enemy structure leaves vision, the view remembers and renders a
**ghost** at its last-seen position/state until the tile is re-seen
(confirming or clearing it). This is the classic "I saw a base here" memory
and it makes Rebel scouting valuable. It lives in the **view**: the entity
view layer stamps a last-seen record per enemy structure id when it
transitions out of visible. No sim state, no hash impact — the sim has no
rule that consults memory in M4. (The moment some future rule *does* — a
trigger that fires on remembered structures, say — it migrates into the sim
per the M3 seam; nothing in M4 forces that.)

### 6.3 Capsule detection (sim)

The one vision feature that *is* sim work, because it changes what a player
can *see* — and therefore react to. The Watcher (and any entity authoring
`detects_capsules: true`) reveals **enemy aerial entities** (in-flight Hive
capsules, M3 §4.5) within its `sight`, even though capsules project no
sight and fog would otherwise hide them.

- During the vision recompute (every `VISION_PERIOD` ticks, M3 §4.4), after
  the tile visibility pass, each detector stamps **visibility around any
  enemy aerial entity within `sight`** (center-to-center), so the capsule's
  cells become visible to the detecting player. This rides the existing
  per-player visibility bitmap — no new data structure, derived and never
  hashed like the rest of vision.
- The view raises a **detection ping** (a one-shot UI event, design.md's
  "mini-warning ping") when a previously-hidden enemy capsule becomes
  visible via detection — the Rebel's "a base is dropping *there*" warning.
  The ping is presentation (view-side, fired off the visibility delta); the
  sim only supplies the now-visible capsule.

This is the anti-Hive counterplay made real: the Hive gambles a capsule
into fog (M3 §4.5), and a Rebel who *invested in detection* gets to contest
the landing instead of discovering the base when it shells them. It is also
why `detects_capsules` is a data field, not a Watcher special case — a
custom map can put detection on anything.

### 6.4 Orders into fog and stale targets

Three-state fog and last-seen memory (§6.1–6.2) force a question M4 must
answer — and surface a bug M3 already has: **what happens when an order is
contradicted by the time the army arrives and regains vision** (an attack on
a structure that is gone, a target that fled into fog)? The live M3 wrongness
behind it: a context order tapped into fog **silently becomes an attack order
when ground truth has a target there**, even with no player vision — the sim
leaks the target's existence to anyone who tap-tests the dark. M4 closes the
leak and defines the arrival behavior on one principle:

**Orders resolve from what the player legitimately knows — current vision
plus remembered ghosts — never from sim ground truth.**

- **Context-order resolution is knowledge-gated (UI).** The tap-to-order
  resolver (design.md select-then-order) may pick an *entity* target only from
  what the ordering player can currently see or remembers as a last-seen ghost
  (§6.2). A tap on a fogged cell with no known entity resolves to a **move**
  (or attack-move, if that verb is held) to the *location* — never to an
  attack on a unit the player cannot see. This closes the M3 leak at the
  source: the resolver consults the player's visible/known set, not the sim's
  entity list.
- **Attacks carry a fallback position (sim).** An `ATTACK` (and attack-move)
  command carries the target's last-known `x,y` alongside the target id. If
  the target id is already invalid at execution (dead, or a stale ghost that
  has since moved) or **becomes** invalid mid-approach (the target dies or
  leaves the unit's `sight`), the order degrades deterministically to
  **attack-move to the last-known position**: the unit advances there,
  re-acquires whatever hostile is actually present on arrival (normal
  attack-move semantics, §9.3), and otherwise holds. No psychic re-targeting,
  no chasing a vanished unit across the map.
- **Stale ghosts self-correct.** Order an attack on a last-seen structure
  ghost and the army marches to that spot; regained vision on arrival either
  confirms the structure (engage) or clears the ghost (the attack-move finds
  nothing and the unit holds). The ghost was the player's best information;
  acting on it and discovering it stale is intended play, not an error — and
  it is exactly why a vision faction invests in keeping ghosts fresh (§18).

This is mostly a **UI/command-construction** fix (the resolver) plus a
**small sim addition** (the attack-order fallback position and its
degrade-to-attack-move rule, folded into existing order handling — no new
system). It is the information milestone being honest: the Rebels' whole
pitch is *acting on knowledge*, so the game must never quietly hand them — or
the Hive — knowledge they did not earn.

### 6.5 Walls as vision blockers — the height-LOS seed (sim)

If information is the Rebel pillar, a wall should deny it, not just deny
passage. And because this is a 3D world that *will* grow high ground (cliffs,
ramps), the honest way to make a wall block sight is **not** a bespoke
"opaque cell" flag — it is the first instance of the **height-based line of
sight** the terrain system needs anyway. A wall simply **stands one or two
levels tall** and occludes like any elevation would. M4 ships flat terrain
(height 0 everywhere), so the only thing with height *is* a wall — but the
rule is written general, so cliffs and ramps drop into it for free in M5+.

Each structure carries an **`los_height`** (int LOS levels; 0 = transparent,
the default; Barricades author ~2). Folded into the M3 vision recompute
(§6.3, every `VISION_PERIOD` ticks):

- **Vision is height-gated line of sight.** A tile is visible to player P
  only if some sighting source has center-to-center distance ≤ `sight` *and*
  a clear integer-grid line to it — the deterministic supercover primitive
  pathing and the wall stroke already use (design.md) — where a crossed cell
  blocks the line once its `los_height` rises above the sightline's height at
  that point (standard RTS high-ground occlusion). On flat M4 terrain that
  reduces to "a wall hides what's directly behind it"; with real elevation
  later the same test yields "high ground sees over low, low can't see onto
  high." A source sees up to and including its own wall — only beyond it is
  shadowed.
- **Flying entities are exempt — height occludes the ground plane.** Aerial
  entities (in-flight Hive capsules today; any unit authored `flying` later)
  are seen *over* walls and high ground: their visibility uses the
  radius-only test (and capsule detection, §6.3), never the occluded one.
  This is exactly the asked behavior — **a wall blocks vision of enemy units
  that aren't flying** — and the Hive's answer to a walled base is the
  capsule it already flies: walls don't stop what drops from above, so the
  Rebel wall stays a strong-but-not-absolute defense and the capsule keeps
  its reason to exist.
- **Still derived, never hashed.** Occlusion recomputes from authoritative
  state (wall/terrain heights + sight stats) each vision tick, like the rest
  of fog (§6.3) — no new hashed field, nothing added to the desync surface,
  ports with the vision system (§15). Perf: LOS work happens only near cells
  with `los_height > 0`, so the common open-ground disc stays the cheap M3
  stamp; a base ringed in wall pays a bounded shadow-cast over its perimeter,
  on the `VISION_PERIOD` cadence M3 already throttles.

**Attacks across walls (M4: vision-gated; trajectory LOS deferred).**
Auto-acquisition already follows the firing unit's own sight by the
`acquire_range ≤ sight` convention (M3 §4.4), so a unit doesn't auto-target
through a wall it can't see past — for free. But **when the player has vision
of a target by other means (a spotter, a flyer, detection), M4 lets the unit
attack it across the wall** (decided): attacks are gated by *vision*, not by a
separate line-of-fire test. The richer model we want eventually — a weapon
**`trajectory`** of `direct` (a gunner's straight line, stopped by the wall)
vs `lobbed` (an archer's/mortar's arc, which clears it) — is **designed but
deferred past M4**: a per-attack direct-LOS check fires constantly and feeds
back into movement (a blocked unit must reposition for a shot, re-pathing
often), and that cost is not affordable in GDScript. Revisit once the sim is
C++ (§15; design.md "The GDExtension port"); §18 tracks it.


## 7. Win/loss and the match loop

M4 is the "first full game loop," so the game needs to be able to **end**.

### 7.1 The defeat condition (data-driven)

*(Decided for M4: keep it simple — the town-hall rule.)* A player is
**eliminated** when they hold **no COMPLETE structure flagged `is_main`**
(§11) — the Stronghold for the Hive, the HQ for the Rebels. Lose your last
*complete* main structure and you are out, even if a replacement is in
flight or under construction. This is the classic "lose your town hall, lose
the game" rule, and it keys on one catalog flag rather than reasoning about
build/train capability:

- **Hive:** no complete Stronghold ⇒ eliminated — design.md's "losing the
  last complete Stronghold is the Hive defeat condition," verbatim.
- **Rebels:** no complete HQ ⇒ eliminated. (A surviving worker that *could*
  rebuild does **not** save you under this rule — deliberately simple for
  M4; if playtests want "fight on with a worker," that's the override
  below, not a code change.)

The rule is the **default**, and per §8.4's philosophy the win/loss
condition is itself **data** — a map manifest can override it in M5
("destroy all structures," "kill the hero unit," a timed score). M4 ships
only this default plus the override *hook* (a manifest field read at load,
unused by M4 maps), so the M5 editor extends it without touching sim code.

### 7.2 Match-over and elimination state

- The sim checks each player for a surviving complete `is_main` structure
  each tick (cheap — a flag test during the structure scan it already runs)
  and **latches** elimination: `eliminated_tick[player]` is hashed state,
  set once when the player first holds no complete main structure and never
  cleared. Latching avoids flicker (and means a main structure that
  finishes *after* the latch doesn't un-eliminate — losing the town hall is
  final) and gives the view a definite moment.
- **Match-over** is derived: when exactly one player (or, later, one team)
  remains un-eliminated, the match is over and that player is the winner.
  M4 is strictly 1v1, so this is "the other player got eliminated." Teams
  and FFA are a trivial generalization left for when a mode needs them.
- On elimination, a player's surviving units are **not** force-killed in
  the sim (lockstep doesn't need that, and a replay wants the truth); the
  *match* simply ends and the result screen shows. (A "leftover units keep
  fighting until the result screen is dismissed" choice is view-side
  flavor, not sim.)

Elimination and match result are exposed via a read API
(`match_result() → {over, winner, eliminated: {...}}`) following the M3
batch-read pattern — O(1) per tick across the boundary.

### 7.3 The Quick Match loop

design.md "Game Modes": Quick Match — pick a faction, play a map, slots
filled by bots or humans. M4 ships the single-human-vs-one-bot slice:

1. **Setup screen** (minimal): choose your faction (Hive / Rebels), the
   opponent is a bot of the other faction (faction-choice for the bot and
   difficulty are dropdowns; map is fixed to the M4 1v1 map). This is a
   plain menu scene, not console UI — it's pre-match, outside the
   in-game UI-as-data system.
2. **Spawn:** the map (§7.4) defines two player slots; the loader spawns
   both bases. `main.gd` becomes match-aware: it wires the local human to
   player 1 and a `BotCommander` (§8) to player 2 as a second command
   source.
3. **Play:** identical command pipeline for both sources (design.md:
   "single-player vs bots uses the identical command pipeline").
4. **Result:** on `match_result().over`, a **victory/defeat screen**
   (faction-skinnable, but a plain overlay in M4) with a **Rematch** (same
   setup, new seed) and **Exit to setup** action.

### 7.4 The 1v1 map

A new `maps/dev_clash.json` — the same format as `dev_arena.json`, now
exercising the parts M3 stubbed:

- `catalog_layers: [core.json, hive.json, rebels.json]` — both factions
  compiled into one catalog (the loader already merges an ordered layer
  list; this is its first multi-faction use).
- Two player slots: `{id:1, faction:"hive"}` and `{id:2, faction:"rebels"}`
  (the setup screen swaps which is human). Mirrored start positions,
  mirrored Alloy deposits and a Flux vent per start, contested resources in
  the middle.
- `dev_arena.json` stays as the Hive sandbox/test map; `dev_clash.json` is
  the match map.


## 8. The scripted bot

design.md is explicit: "the bot is effectively a player issuing console
commands, which keeps bot work and player-AI work the same system," and
"a bot is a command source, the local human is another." M4 takes that
literally.

### 8.1 Architecture: a command source outside the wall

The bot lives in a new `src/ai/` directory (the sim wall stays clean; this
is *not* sim code). `BotCommander`:

- **Reads** sim state through the same read-only view APIs the UI uses
  (resources, bandwidth/Crew, entity positions/types, fog bitmaps, match
  state). It never touches sim internals or mutates entities.
- **Emits** ordinary `SimCommand`s through the same `schedule(cmd, at_tick)`
  path the human's UI uses. Every bot action is a command a human could
  issue — if the bot needs an action the command vocabulary can't express,
  that's a *gap in the command API*, and closing it benefits the human too.
  (This is the load-test value: the bot is the command surface's fuzzer.)
- **Runs at human cadence,** not every tick: a "think" pass every
  `BOT_THINK_PERIOD` ticks (placeholder ~10 ticks / 0.5 s). The bot is a
  *commander*, not an APM monster — this is the design pillar applied to
  the AI itself. Low cadence is also cheap.
- **Has its own seeded RNG** (outside the wall, so it may use ordinary
  randomness — it is not sim code). Seeded so a given match seed yields a
  reproducible bot. Its commands enter the scheduled command stream, so
  **replays and lockstep reproduce the bot exactly from the recorded
  stream regardless of the bot's internal determinism** (a replay is seed +
  commands; the bot's commands are *in* the commands).

### 8.2 Behavior (competent, not clever)

A small macro state machine — enough to make a new player work, explicitly
*not* a strong AI (that's post-M7). Per think pass, in priority order:

- **Economy maintenance:** keep workers/nanos on resources (Rebels: set the
  economy dials — `worker_target`, alloy/flux and build/mine ratios — and let
  auto-replace refill losses; Hive: keep nanos on alloy/flux), expand (a new
  HQ/Refinery, or a Worker onto a fresh vent) when the current source
  saturates or depletes.
- **Tech/supply:** build supply (Housing / Relay) before hitting the cap;
  build the structures needed to unlock the next unit tier when Flux allows.
- **Army production:** train a placeholder composition up to a target army
  value scaled by difficulty.
- **Aggression:** when army value crosses an attack threshold, gather at a
  staging point and attack-move toward the enemy's nearest known producer
  (using fog-aware reads — it attacks what it can see/remember, no
  omniscience). Retreat the army home when it falls below a retreat
  threshold or its base is attacked.
- **Defense:** pull the army back to defend when an enemy is detected near
  its base (Rebels lean on this — and on Watchers — matching the faction's
  defensive identity).

Both factions are driven by the *same* `BotCommander`, **hardcoded in
GDScript** for M4 — the FSM, its faction build-order tables, and its
difficulty presets all live in code (think cadence, army threshold,
expansion aggression, whether it micro-retreats). M4 deliberately does
**not** make the bot a data-driven or authorable system (see §8.4); a few
named difficulty tiers are code constants, not an override layer.

### 8.3 Determinism and the M6 seam

For M4 (one machine) the bot runs locally and schedules commands; nothing
about determinism inside the sim is affected (the bot is outside the wall,
the sim still consumes only commands). For M6 lockstep, **exactly one peer
owns each bot slot** and forwards the bot's commands on the wire like a
human's; running the same bot on every peer would diverge (it reads
view-side, RNG-bearing state). M4 builds the bot so this is a wiring change,
not a rewrite: the bot already produces a command stream addressed to a
player slot — M6 decides who runs it and puts that stream on the wire. This
is flagged, not solved, here.

### 8.4 Editability: hardcoded now, triggers in M5, scriptable AI maybe-never

*(Decided during M4 design.)* The bot's behavior is **hardcoded GDScript in
M4** — not data, not authorable. We considered making AI a data-driven
element editable like everything else and deliberately chose not to, on a
clean split of needs:

- **Scenario / map-specific AI** (waves, boss phases, a mission's scripted
  enemy) is **not** a separate system — it is the **M5 trigger interpreter**
  (design.md "Triggers and scripting"). A trigger that issues commands to a
  computer player *is* authorable AI for that map, and it costs no new
  schema because we are building triggers regardless. So the editor's
  AI-authoring story arrives in M5, for free, as triggers — *not* as a bot
  catalog.
- **A complete, general, "play normal maps better than the defaults"
  community AI** — the real motivation for a bespoke AI DSL — is explicitly
  a **future bridge, not an M4/M5 commitment.** It is genuinely harder than
  trigger scripting (a general melee brain, not a per-map script) and
  speculative until someone actually wants to write one. Crucially, the
  **command-source seam this section builds is exactly the plug such an AI
  would slot into**: a player slot fed by an alternative command source.
  Deferring it costs us nothing — we are not designing against it, just not
  designing *for* it yet.

So: hardcode the bot now; author scenario AI with triggers in M5; revisit
player-scriptable general AI only if and when the ask is real. This keeps
the M4 schema flat (no AI fields anywhere) and avoids the genuine trap —
shipping a bespoke AI scripting language in M4 that would overlap and
duplicate the M5 trigger language (two scripting systems for one job). It
also feeds design.md Open Q #11 / §8.3: whatever "authorable AI" eventually
means, its heaviest form (per-tick AI decisions in triggers) is a load the
trigger-interpreter-placement question must weigh.


## 9. Unit AI v1 — stances and the Tactics tab

design.md "Unit AI & Tactics": "give intent, army executes." `SET_TACTIC`
is already a declared command kind (unhandled). M4 makes it real with a
deliberately small, sim-side behavior layer — enough for the bot and the
player, with the rich version (full priority matrix, per-type rules)
deferred to M7.

### 9.1 Stances

Each unit carries a `stance` (hashed) ∈ `DEFENSIVE | BALANCED | RECKLESS |
SKIRMISH` (default `BALANCED` = current M3 behavior, so existing tests are
unchanged). Stances modify the existing movement and combat systems — no
new system, just branches the systems already have a place for:

- **DEFENSIVE** — short leash: the unit acquires and engages only within a
  small radius of its **anchor** (its current position when set, or its
  hold/standing point); pulled past the leash, it returns. Holds ground.
- **BALANCED** — M3 behavior: acquires within `acquire_range`, chases a bit,
  returns to orders when idle.
- **RECKLESS** — long/no leash: always pursues an acquired target, chases
  across the map. (The bot's attack waves run reckless; defensive groups
  hold.)
- **SKIRMISH** — kite: a ranged unit (`attack_range` > melee threshold)
  whose target closes inside a min-distance backs off to maintain range,
  firing while retreating. Melee units treat skirmish as balanced.

Plus a small set of **priority flags** (hashed bitfield), M4 scope:

- `hold_position` — never move to acquire (fire only at in-range targets);
  the stance-independent "planted" toggle (design.md "hold position").
- `focus_fire` — members of the same designation prefer the
  lowest-id target already engaged by a groupmate, concentrating damage
  (cheap, deterministic; the full target-priority system is M7).

Leash distances and the kite min-distance are global constants in
`core.classes` (tunable, placeholder), not per-unit, in M4.

### 9.2 SET_TACTIC and designations

`SET_TACTIC` (now handled) carries a stance and/or priority-flag changes
for `targets` (entity ids). The Tactics tab (§13.1) issues it for the
current selection or a designation. Per design.md, **tactics persist on the
designation, not the unit:** the designation (UI-side, M3 §6.1) stores its
stance/flags and **re-issues `SET_TACTIC` to new members** when membership
changes (reinforcements join → they inherit). This is occasional UI traffic
(on membership change), never per-tick — the *maintenance* of stance
behavior is sim-side (the unit holds its stance and the systems honor it
each tick); the *inheritance* is UI-side re-application. This reconciles
design.md's two statements (army "executes and maintains" = sim; "tactics
persist on the designation" = UI re-applies) without either lying.

### 9.3 PATROL made real

`PATROL` (declared, currently aliased to MOVE) becomes a real order: stored
as **two endpoints** (the unit's position at order time and the target),
the unit attack-moves between them, swapping endpoints on arrival,
re-acquiring along each leg (attack-move semantics, which already exist).
Hashed (the endpoints + which leg). Modest, and it completes the M1 radial's
patrol verb that has been a MOVE stand-in since M1.


## 10. The Strategy tab (mostly deferred)

design.md's Strategy tab (attack base / retreat-defend / raid-along-path /
escort, compiled to maintained standing orders) is explicitly the **M7**
"full version" per the roadmap. M4 does **not** ship the player-facing
Strategy tab. What M4 *does* ship is the **sim primitive** those orders
will compile to, because the bot needs it and stances use it:

- A unit's **anchor** (a hold/defend point, hashed) + DEFENSIVE stance =
  "defend here": the unit holds the anchor, engages threats within leash,
  returns when idle. That is the atom of "defend Bravo." The bot issues it
  directly (move to staging + defensive stance); the player gets it via
  hold-position + the Tactics tab.
- Attack-move + RECKLESS = "attack toward there." Patrol = "raid this
  line."

So the *behaviors* design.md's Strategy verbs need exist in M4 as
primitives; the **composition UI** that names them "Raid", "Escort",
"Defend Bravo" and maintains them per-designation is M7. The Strategy tab
keeps its M3 placeholder label, updated to point at the primitives ("group
stances and patrols are in the Tactics tab and viewport; composed standing
orders land in M7"). This keeps M4's surface honest and avoids half-building
a system the roadmap dates later.


## 11. Catalog / schema additions

Small, additive, all schema-declared (CLAUDE.md / M3 §2.3 — unknown `sim`
fields stay a compile error).

**`unit`** gains:

| Field | Type | Notes |
|---|---|---|
| `carry_capacity` | int | > 0 ⇒ harvester (§3); 0 for combat units |
| `harvest_rate` | fixed | units/sec extracted while HARVESTING |
| `build_rate` | fixed | construction progress/sec while BUILDING (worker build, §4) |
| `repair_rate` | fixed | hp/sec while repairing (§4.2); reuses the global if absent |
| `detects_capsules` | bool | reveals enemy aerial entities in `sight` (§6.3) |
| `stance` | enum | *default* stance (`balanced`); units author starting stance, SET_TACTIC overrides |

**`structure`** gains:

| Field | Type | Notes |
|---|---|---|
| `is_depot` | bool | worker harvest drop-off (§3); **HQ only** in M4 (Alloy + refined Flux). The Refinery is a *source*, not a depot |
| `is_main` | bool | "town hall" — the default elimination rule keys on it (§7.1); Stronghold + HQ true |
| `detects_capsules` | bool | as unit (static detectors) |
| `los_height` | int | LOS levels the structure stands (§6.5); 0 = transparent (default), Barricade ~2. Height-gated vision occlusion — the seed of the high-ground LOS system. Aerial entities see over it |
| `is_refinery` | bool | standalone Flux processor (§3.1): auto-links Flux vents within `refinery_radius` and acts as a high-rate Flux harvest source |
| `refinery_radius` | fixed | vent auto-link radius for `is_refinery` structures (§3.1); a global default may be authored per-entry to override |
| `linked_vents` | id list | *compiled, not authored* — the vents an `is_refinery` structure auto-linked at COMPLETE (§3.1); not in source data |
| `needs_builder` | bool | *compiled, not authored* — set true when spawned via `mechanic: worker` (§4.1), including each drawn-wall Barricade segment (§4.4); authors don't write it |

**`ability`** — no new kind. `mechanic: worker` (already in the
`BuildMechanic` enum) is now handled; the `build` schema is unchanged.

**`classes`** gains the `construction` armor class and its matrix column
(§4.3), plus global constants the new systems read: `build_rate` /
`harvest_rate` / `repair_rate` defaults, `raw_flux_rate` and
`raw_flux_carry` (the slow rate and small load cap of direct vent mining,
§3.1), `refinery_radius` default (§3.1),
`max_builders` and `accel_cost_rate` (multi-worker acceleration, §4.1),
`leash_default`, `leash_defensive`, `kite_min_distance` (§9.1). All
fixed/ticks/int, authored as decimal strings per M3 §2.3.

The Rebel catalog also adds the **Barricade** structure (§4.4): an ordinary
`structure` entry with a 1×1 pathing-cell footprint, built by
`mechanic: worker`. No new field — drawn walls are a *command/UI* mechanic
(§4.4, §12), not a schema one.

Inheritance, hashing, and the compiled-catalog shape are unchanged — these
are new fields in the existing tables, folded into the catalog content hash
(M3 §2.4) automatically.


## 12. New and changed commands

`SimCommand.Kind` adds two values and activates two declared ones:

| Kind | targets | params | Notes |
|---|---|---|---|
| `MINE` | `[worker_ids]` | `node` (entity id) | **New.** Manual harvest order onto an Alloy deposit, Flux vent (direct, §3.1), or Refinery. No per-unit pin — instead it nudges the player's economy dials toward that task (§3.2). The Rebel `context_orders.resource` resolves to this (§13.2). |
| `SET_ECONOMY` | `[player-scope]` | `worker_target` (int), `alloy_flux_ratio` (fixed), `build_mine_ratio` (fixed), `auto_repair` (bool) | **New.** The Economy-tab intent dials (§3.2). Scoped per player; one command carries the whole dial set, emitted on slider release. *(Replaces the earlier per-node `ASSIGN_WORKERS` sketch.)* |
| `SET_TACTIC` | `[unit_ids]` | `stance` (enum int), `flags` (int bitfield) | **Activated** (was declared). §9.2. |
| `PATROL` | `[unit_ids]` | `x`, `y` (fixed) | **Activated as real patrol** (was MOVE-aliased). §9.3. Endpoint A is the unit's position at execution. |
| `BUILD` | `[builder_id]` | `type`, `cx`, `cy` (+ existing) | **Extended:** `mechanic: worker` branch (§4) — no capsule, builder travels. M3 capsule path unchanged. |
| `BUILD_WALL` | `[player-scope]` | `cells` (ordered int list) | **New.** Installs a per-player wall plan from a drawn stroke (§4.4); build-reserve workers raise Barricade segments in stroke order. A `CANCEL` on the plan clears the remaining (unbuilt) queue. |
| `REPAIR` | `[worker_ids]` | `target` (structure id) | **New (thin):** worker→damaged own structure (§4.2); folds into the build/BUILDING path. |
| `ATTACK` | `[unit_ids]` | `target` (id), `x`, `y` (fixed) | **Extended:** carries the target's last-known position so a target lost to death or fog degrades to attack-move-to-`x,y` (§6.4). M1/M2 attack semantics otherwise unchanged. |

`params` still carry only ints (ids, cells, fixed, enum ints, bitfields) —
no strings on the wire (M3 §4.9), so M6 serialization and hashing stay
uniform. New kinds are appended to the enum (existing ordinals unchanged →
no replay/hash churn for M3 streams).


## 13. UI work

### 13.1 The Tactics tab (v1)

The M3 placeholder becomes real, scoped to stances + the two priority flags
(§9). A new UI-catalog widget `stance_picker`: a row of stance buttons
(data-driven labels/icons) + toggles for `hold_position` and `focus_fire`,
acting on the current selection or the active designation; emits
`SET_TACTIC`. Like every widget, it's engine-coded mechanics parameterized
by data (which stances exist, their labels) — the *meaning* is catalog
data. Persisting the choice on the designation (re-apply to new members) is
the designation layer's job (§9.2), reusing the M3 `designations.gd` plumbing.

### 13.2 The Rebel UI layer

The proof that "UI as data" carries a whole second faction. A new UI
catalog layer for the Rebels (the UI catalog's faction/map override story,
M3 §2.1, realized) overrides:

- **Supply label:** "Crew" + icon, on the HUD supply slot (§5).
- **Context orders:** `resource → mine` (the real Mine order, §12) — where
  the Hive layer maps `resource → move` (M3 §6.7, the dividend now paid:
  the Hive has no workers, the Rebels do, and the difference is *one line of
  data*).
- **Build/Train grids:** populate from the Rebel catalog automatically
  (already catalog-driven; no UI work beyond the data layer).
- **Economy tab:** the Rebel economy widget is **worker intent dials**, not
  nano sliders — a `worker_dials` widget (a `worker_target` stepper, an
  alloy/flux ratio slider, a build/mine ratio slider, an `auto_repair` toggle,
  plus a live "workers per task / income" readout), the Rebel analog of
  `alloc_sliders`, emitting `SET_ECONOMY` (§3.2). The tab id is the same
  ("economy"); the *widget bound to it* is faction data. (Two widgets, one tab
  slot — precisely the UI-as-data split.)
- **Build tab — draw-wall verb:** the Rebel Build layer adds a "build wall"
  verb that arms the modal stroke and emits `BUILD_WALL` (§4.4). The stroke
  rasterization and the segment-queue construction are engine mechanics; that
  the Rebels *have* a wall verb (and the Hive does not) is one line of layer
  data.
- **Skin:** Rebel colors/theme on the same console, buttons, chips
  (design.md "Faction skins").

The main faction lift: the `worker_dials` widget, the draw-wall stroke
handling, and the Rebel UI JSON layer. Everything else is data the existing
widgets already consume.

### 13.3 Match UI

- **Setup screen** (§7.3): a plain menu scene — faction toggle, bot
  faction + difficulty, Start. Pre-match, outside the in-game UI-as-data
  system (it configures the match, it isn't part of it).
- **Result screen** (§7.3): victory/defeat overlay with Rematch / Exit;
  faction-skinnable but a plain overlay in M4.
- **Capsule-detection ping** (§6.3): a transient minimap/edge warning when
  a Watcher reveals an incoming enemy capsule — view-side, fired off the
  visibility delta.

### 13.4 HUD

The supply readout is relabeled by faction (§5); the Alloy/Flux readout is
unchanged. No new HUD widgets — Crew is Bandwidth with a Rebel label.


## 14. View layer and assets

### 14.1 Conventions

Unchanged from M3 §7.1 — catalog-driven views with primitive fallbacks;
Blender→glTF into `assets/models/rebels/<entry>.glb`; `view` block
references model + clip names. Per the M3 project decision, **M4 ships on
catalog-driven primitives first** (distinct silhouettes/colors per Rebel
entry); models land incrementally without code changes.

### 14.2 New view work

- **Three-state fog** (§6.1): the fog overlay accumulates `explored` and
  renders black / dim / bright. View-only.
- **Last-seen ghosts** (§6.2): enemy structures render as dimmed ghosts at
  last-seen state until re-seen. View-only.
- **Worker harvest visuals:** carry indicator (a worker visibly hauling),
  harvest "tick" at the source, the walk-to-depot loop reading naturally.
- **Worker build visuals:** a worker planted at a GROWING site (reuses the
  M3 growth mesh + progress ring); paused-construction read when no worker
  is present.
- **Capsule-detection ping** (§13.3).
- **Rebel roster primitives:** Rebels read chunky/mechanical, rust + canvas
  + mismatched salvage (design.md art direction) — distinct from Hive's
  iridescent skitter even as colored boxes.

### 14.3 Asset list (incremental)

Rebel models (low-poly, flat-shaded, silhouette-first): HQ, Housing,
Refinery, Worker (+ carry/build poses), Gunner, Watcher, Demolisher,
Marauder bike. ~8 meshes, ~16 clips, landing after the sim is green (M3's
ordering: assets parallel to and trailing the systems).


## 15. What this means for the GDExtension port

Consistent with M3 §4.12: **everything new in the sim ports with the rest of
`src/sim/`, and the bot never ports.** Specifically:

- **Worker economy, worker build, drawn walls, stances, patrol, capsule
  detection, height-LOS vision occlusion, elimination latching** all
  read/write entity state per tick inside the wall — they port mechanically
  (value state, no retained references, ascending-id iteration). The
  economy-dial reconcile is the only new per-player loop and it's O(workers),
  trivially translated; the wall plan is a per-player cell queue drained by
  the same build path; height-gated occlusion stays *derived* (recomputed
  each vision tick, never hashed) like all of fog, so it adds nothing to the
  parity surface — and it's a system the C++ port *wants* early, since
  per-tile LOS is exactly the kind of inner loop the port exists to speed
  (the future direct-fire trajectory check, §6.5, is being held for that same
  reason).
- **The bot is *already* on the far side of the wall** — it consumes batch
  view reads and produces commands, the boundary-friendly shape the port
  exists to preserve. It is the cleanest possible confirmation that the
  command API is the whole interface: if the bot works through it, C++ sim
  + GDScript bot works unchanged.
- **Three-state fog and last-seen memory are view-side** — they never enter
  the sim, so they never port; they read the same packed visibility bitmaps
  the C++ sim will emit.
- **Match result** is one O(1) batch read per tick, like every other view
  accessor.

The M4 systems were chosen, where there was a choice, to *not* grow the
port: supply is reused, fog memory is presentation, the bot is external. The
only real port growth is the worker harvest loop — unavoidable, it's the
Rebel economy — and it is structurally identical to the Hive economy that
already ports.


## 16. Tests

Per repo convention, one headless script per check in `tests/`:

- `rebel_economy_check.gd` — the harvest loop exact: worker fills to
  capacity at `harvest_rate`, deposits exact amounts at the nearest depot
  (HQ, id tiebreak verified), node `amount` decrements with throughput shared
  across workers, worker death drops carry (no bank). Flux both ways: direct
  vent mining accrues at `raw_flux_rate` and draws the vent down; a Refinery
  auto-links the vents within `refinery_radius` at COMPLETE and harvests at
  `harvest_rate`, drawing its linked vents down in id order. The **dial
  reconcile**: `build_mine_ratio`/`alloy_flux_ratio` produce the right
  per-task counts, the build reserve sources a builder for a BUILD (nearest
  reserve worker, then a harvester when empty), `worker_target` auto-replaces
  a killed worker, and a manual `MINE` nudges the dials rather than pinning a
  unit. Golden balances/positions at fixed ticks.
- `worker_build_check.gd` — worker travels to site, GROWING freezes when
  the worker is pulled and resumes when returned, cost reserved at order
  and refunded on pre-GROWING cancel, partial refund after, repair heals a
  damaged structure, anti-construction multiplier (Demolisher vs a GROWING
  nest vs a Gunner vs a Mite — exact damage from the matrix). **Drawn walls
  (§4.4):** a `BUILD_WALL` stroke installs an ordered plan; workers raise
  segments in stroke order (pending segments block/cost nothing until
  started); parallel workers drain the queue deterministically; a mid-stroke
  `CANCEL` leaves exactly the built/GROWING segments with nothing pending
  charged.
- `fog_orders_check.gd` — orders under fog (§6.4): a context tap on a fogged
  enemy with no player vision resolves to a move, **not** an auto-attack (the
  M3 leak fixed); an `ATTACK` whose target dies or leaves `sight` mid-approach
  degrades to attack-move at the carried last-known `x,y` and re-acquires only
  what is actually present on arrival; a stale ghost target produces a march
  that finds nothing and holds. **Wall occlusion (§6.5):** an `los_height`
  Barricade hides an enemy ground unit directly behind it from a viewer in
  line, while an aerial capsule over the same wall stays visible and the
  viewer still sees up to its own wall; and a unit *can* attack a target
  across the wall when a separate spotter supplies vision (M4 vision-gated
  rule). Deterministic across the vision recompute cadence.
- `victory_check.gd` — the town-hall elimination rule (§7.1) both ways:
  eliminated the tick the last COMPLETE `is_main` structure dies; an
  in-flight/GROWING replacement does **not** save the player; a main
  structure that finishes after the latch does **not** un-eliminate;
  match-over fires with one survivor; elimination latches (hashed) and
  doesn't un-set.
- `tactics_check.gd` — stances change behavior deterministically: defensive
  leashes and returns, reckless chases, skirmish kites at min-distance,
  hold_position never moves to acquire, focus_fire concentrates; PATROL
  swaps endpoints and re-acquires.
- `bot_check.gd` — a recorded bot run is deterministic: a `BotCommander`
  with a fixed seed vs a do-nothing opponent reaches elimination by a known
  tick, and the *recorded command stream* re-run through the sim produces
  the identical hash stream (proving "replay reproduces the bot from
  commands"). Also a validity smoke test: every command the bot emits over
  a match passes sim validation (no malformed/illegal commands).
- `determinism_check.gd` — extended: the M4 scenario (Hive vs Rebels, both
  economies, bot stream, played to elimination, vision recompute ticks
  covered) twice from one seed → identical hash streams. The canary for
  "forgot to hash a new field" (carry, stance, anchor, patrol endpoints,
  needs_builder, eliminated_tick, economy dials, refinery `linked_vents`,
  wall plan, attack fallback position).
- `perf_check.gd` — extended: the 150-unit melee now runs with **two**
  running economies (Hive nanos + Rebel worker fleet) to keep the
  measurement honest against the §1 exit criterion and the GDExtension
  tripwire.
- `ui_catalog_check.gd` — extended: the Rebel UI layer (Crew label, mine
  context order, the draw-wall verb, `worker_dials` + `stance_picker`
  widgets) loads and overrides correctly; both faction layers validate.
- `catalog_check.gd` — extended: `rebels.json` compiles, the `construction`
  armor column and new unit/structure fields validate, the merged
  three-layer catalog (`core + hive + rebels`) hash is stable (golden).


## 17. Implementation order

Dependency-driven; each step lands with its tests green:

1. **Catalog/schema additions** (§11): new unit/structure fields, the
   `construction` armor class + matrix column, the global constants;
   `rebels.json` (data-only entries that need no new sim yet — HQ, Housing,
   Gunner, Watcher, Marauder, all expressible on M3 systems). `catalog_check`
   extends here.
2. **Supply as Crew** (§5): Rebel supply data + HUD relabel via the Rebel
   UI layer. (Almost free — proves the layer mechanism early.)
3. **Worker harvest economy** (§3): harvest state machine, HQ depot, direct
   vent mining + Refinery auto-link/harvest, the dial reconcile +
   `SET_ECONOMY`/`MINE`. `rebel_economy_check` green.
4. **Worker build mechanic** (§4): `mechanic: worker` branch, `needs_builder`,
   travel/BUILDING/pause, repair, anti-construction class; then **drawn walls**
   (§4.4) — `BUILD_WALL`, the wall plan/segment queue, cancel-leaves-partial,
   riding the same build path. `worker_build_check` green.
5. **Win/loss** (§7.1–7.2): the elimination rule, latch, `match_result()`.
   `victory_check` green.
6. **Unit AI v1** (§9): stances, priority flags, `SET_TACTIC`, real PATROL.
   `tactics_check` green. **The sim is feature-complete for M4 here** —
   `determinism_check` extension passes before any bot or match-UI work.
7. **Vision additions** (§6.3–6.5): capsule detection, wall LOS occlusion
   (depends on walls from step 4), knowledge-gated context orders, and the
   attack-order degrade-to-attack-move fallback. `fog_orders_check` green.
8. **The bot** (§8): `BotCommander`, in-code faction build-order tables and
   difficulty presets (hardcoded — no AI data layer, §8.4). `bot_check` green.
9. **Match loop + UI** (§7.3, §13.3): match-aware `main.gd`, `dev_clash.json`,
   setup + result screens, second command source wired to the bot.
10. **Rebel UI layer + Tactics tab** (§13.1–13.2): `worker_dials`,
    `stance_picker`, the draw-wall verb, Rebel skin, mine context order.
    `ui_catalog_check` extends.
11. **View work** (§14): three-state fog, last-seen ghosts, worker visuals,
    detection ping, Rebel primitives.
12. **Assets** (parallel to 6–11, lands incrementally).
13. **On-device playtest pass** — the milestone bar is "a full match,
    playable on a phone, that you can win or lose against a bot."


## 18. Open questions (need answers before or during M4)

Tracked here so they don't silently become decisions (answers fold back
into this doc).

*Implementation notes (M4 build, 2026-06-17).* The sim is feature-complete
and headless-tested (steps 1–8 + the determinism/perf extensions all green);
the match/UI/view integration is wired but its presentation is unverified
off-device. Small deviations made during implementation, none load-bearing:

- **Worker-built structures spawn GROWING + `needs_builder` immediately**
  (matching §4.1's field table, not a separate "reserved-unstarted" pre-spawn
  state). `needs_builder` zeroes the `Fixed.ONE`/tick auto-progress; a worker
  on site supplies all progress via `build_rate` through the `assist_bonus`
  channel. Consequence: the "full refund before GROWING begins" window (§4.1)
  collapses for direct builds — cancel is always the 50% partial — and lives
  instead on the drawn-wall *pending* queue (uncharged until a worker starts a
  segment), which is the same idea.
- **Internal sim moves carry `params.internal = true`** so harvest/build/wall
  travel doesn't detach a worker from its task; a player-issued order (no flag)
  *does* detach — this is the §4.1 "pull the worker, construction pauses" rule.
- **Stances are a thin post-combat layer** (`_stance_system`) using direct
  fixed-point steering, no pathfinding — adequate for the v1 stance set;
  BALANCED is unchanged M3 behavior so existing tests/determinism hold.
- **Wall vision occlusion is computed at build-tile resolution** (a 1×1
  Barricade marks its whole tile an occluder), consistent with the
  tile-resolution fog map and the "sees up to its own wall" rule (§6.5).
- **The bot takes `scout_hints`** (enemy start positions from the match setup)
  to find a fogged base; otherwise it is a pure command source over
  `SimCommand` and its recorded stream replays bit-exactly (`bot_check`).
- **Deferred view polish** (not blocking the game loop, unverified off-device):
  last-seen structure ghosts (§6.2), worker carry/build pose visuals, the
  capsule-detection ping (§6.3), and the pre-match faction-select screen — M4
  runs the local human as Hive vs a Rebel bot on `dev_clash.json` by default.
  The **drawn-wall stroke gesture** (rasterize a finger drag → `BUILD_WALL`)
  is the one viewport interaction still to wire; the `BUILD_WALL` sim path and
  the Rebel "Draw Wall" verb are in place.

1. **Bot difficulty surface** — how many scalars before "difficulty" is
   legible to a player (§8.2)? Starting hypothesis: 3 named tiers backed by
   the scalar bundle.
2. **Skirmish kite vs collision** — kiting ranged units against the
   deterministic push-out (M3) needs playtest: does it read as kiting or as
   jitter? (§9.1)
3. **Last-seen ghost staleness** — how long does a last-seen enemy
   structure ghost persist before it's stale enough to mislead (§6.2)?
   View-side tuning, but a real UX question for the information faction.
4. **Bot ownership in MP** — confirmed M6, but the choice (host owns all
   bot slots vs distributed) wants an early opinion so M4's command-stream
   shape doesn't paint us into a corner (§8.3).
5. **Multi-worker tuning** — the *mechanic* is decided (WC3
   accelerate-for-resources, §4.1); `max_builders`, `accel_cost_rate`, and
   whether the drain is Alloy-only or also Flux are placeholder numbers for
   the tuning pass, not open design.
6. **Refinery buffering** — M4 ships the Refinery as a *live pass-through*:
   it stores nothing, just taps its linked vents faster and at bigger loads
   (§3.1). Adding a Flux *buffer* later (workers top up instantly, expansion
   caching becomes a thing) is an explicit, clean future add — decide if/when
   playtests want the deeper economy. Not blocking.
7. **Economy-dial manual feedback** — when a hand `MINE`/`BUILD` nudges the
   dials (§3.2), how *far* does one order move a slider, and does the slider
   relax back when the task ends or stick? A feel question; the dial model
   itself is decided.
8. **Drawn-wall pricing & gesture** — design.md Open Q #10, now live for the
   Rebels (§4.4): per-cell cost, min/max stroke length, and how the modal
   build-wall stroke coexists with the lasso. Needs playtest; the
   construction *mechanic* (segment queue, cancel-leaves-partial) is decided.
9. **Trajectory line-of-fire (post-M4)** — M4 gates attacks by *vision*
   only: with vision by any means you may fire across a wall (§6.5, decided).
   The wanted refinement — `direct` weapons (straight-line, blocked by walls/
   high ground) vs `lobbed` (arcing, clears them) — is **deferred past M4**:
   the per-attack direct-LOS check recomputes constantly and feeds back into
   pathing, too costly in GDScript. Revisit after the C++ port (§15). Not a
   question of *whether* (we want it), but *when the sim can afford it*.

*Resolved during M4 design (folded into the body):* **multi-worker
construction** ships — additional builders shorten build time and drain
resources while they assist, the WC3 model (§4.1); the **Rebel economy is
intent-dial driven** — `worker_target` (auto-replace, no spending guardrail —
we trust the dial), alloy/flux and build/mine ratios, auto-repair, with
manual orders feeding back into the dials rather than pinning units (§3.2);
the **Refinery is a standalone vent-pooling source** — not built-on-vent, not
a depot, and a *live pass-through* (no stored Flux in M4) that gives workers a
faster rate **and** bigger loads than the slow, light direct-vent-mining
floor (§3.1); the **HQ provides starting Crew (~+10)** so a fresh base has an
opening force (§2.1); the **Marauder bike is ground-only**, anti-air being a
per-unit data choice and the Demolisher the dedicated capsule-killer (§2.1);
**drawn walls are pulled forward from M5** to ride the worker-build mechanic,
and **walls block ground vision by standing tall** — modeled as the first
instance of the height-based high-ground LOS (flyers see over them), with
attacks gated by vision only in M4 and the direct/lobbed line-of-fire check
deferred past the C++ port (§4.4/§6.5, §18);
**orders are knowledge-gated** — context taps and attacks act on what the
player sees/remembers, with attacks degrading to attack-move on a lost
target, fixing the M3 fog-leak (§6.4); the **elimination rule** is the simple
town-hall test — no complete `is_main` structure ⇒ eliminated, an in-flight
replacement does not save you, and the condition is M5-overridable data
(§7.1); **match setup** stays a fixed-map 1v1 human-vs-bot, no map picker or
extra slots in M4 (§7.3, §13.3).

*Also decided earlier and flagged inline:* Crew is the M3 supply mechanic
relabeled, no new field (§5); three-state fog and last-seen memory stay
view-side (§6); the Strategy tab's rich orders defer to M7 while their sim
primitives ship in M4 (§10); the bot is an external command source,
reproduced in replays via its recorded stream (§8); the bot is hardcoded in
M4 — scenario AI becomes M5 triggers, a player-scriptable general AI is a
deferred future bridge that the command-source seam keeps open (§8.4).
