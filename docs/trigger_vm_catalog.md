# Trigger VM — Capability Catalog (first pass)

*Status: first-pass enumeration for review. A working list, not a frozen spec.*

This is the comprehensive "what does our trigger VM need" catalog that
[design_m5.md](design_m5.md) §3 calls for (and design.md Open Q #6). It
enumerates the **language core** (the VM's execution model) and the **standard
library** (the registry of events, queries, actions, and presentation calls a
map can use). It is the menu from which the M5 *initial slice* is cut — the slice
is staged against three target maps (§11), the architecture aims at WC3-class
breadth, and entries beyond the slice are listed so the registry grows by adding
rows, never by redesign (design_m5.md §3.3, §3.10).

## How to read this

Every library entry has a **Kind** and a **Slice**:

- **Kind** — `Core` (language construct, not a registry call) · `Event` (fires a
  trigger) · `Query` (reads sim state, pure, no mutation) · `Action` (mutates
  hashed sim state) · `Pres` (presentation — emits to the view's unhashed event
  queue, never touches sim state, design_m5.md §3.4).
- **Slice** — `✓` in the M5 initial slice (a target map needs it) · `◐` likely
  M5 if cheap, else next · `○` later / parity (no target map needs it yet).

**Determinism rules the language enforces** (design_m5.md §3.8–3.9), so every
entry below obeys them: numbers are `int`/`fixed` (no float type); randomness is
the sim `DRng` only; iteration over groups is ascending entity id; `unit` values
are entity ids (a dead ref reads `null`); strings are presentation-only constants
(never in the hash); execution is op-budget-bounded. Anything an entry returns or
mutates that is sim state is hashed.

`fixed` = 16.16 fixed-point. `T?` = nullable. `group` = unit group (id list).
A **filter** is either a built-in filter constant (§10) or a user predicate
`fn(unit) -> bool`.


## 1. The type system

| Type | Notes |
|---|---|
| `int` | 64-bit integer, truncating division (matches the C++ `int64_t` port). |
| `fixed` | 16.16 fixed-point. The *only* fractional type — there is no float. |
| `bool` | |
| `string` | **Constant only**, presentation-use only (messages). Interned to the constant pool; never hashed (design_m5.md §3.9). |
| `unit` | Reference to a unit/structure entity (an id). `null` if dead/invalid. |
| `player` | A player slot. |
| `point` | An `(x, y)` pair of `fixed` (a map location). |
| `region` | A named map area (pathing-cell rect/area), §3.6. |
| `group` | An ordered set of `unit` (ascending id). Variable-held, hashed. |
| `trigger` | A reference to another trigger (enable/disable/run). |
| `timer` | A reference to a running/paused timer. |
| `unittype` | A catalog entry id for a unit/structure type (e.g. `rebels.gunner`). |
| `abilitytype` | A catalog ability entry id. |
| *enums* | `stance`, `resource`, `relation`, `build_state`, … (§10). |

User-defined functions have typed parameters and a typed (or `void`) return
(design_m5.md §3.2). Generics are out — a function is monomorphic.


## 2. Language core (the VM execution model)

Not registry calls — these are the interpreter's own constructs (design_m5.md
§3.2, §3.7). All `Core`.

| Construct | Form (Lua-flavored) | Slice |
|---|---|---|
| Global variable | declared in a `globals` block; typed | ✓ |
| Local variable | `local x: int = …` (lexically scoped, frame-relative) | ✓ |
| Assignment | `x = expr` | ✓ |
| Arithmetic | `+ - * / %` (int/fixed; truncating `/`) | ✓ |
| Comparison | `== != < <= > >=` | ✓ |
| Boolean | `and or not` (short-circuit) | ✓ |
| Literals | int, `fixed` decimal, duration `30s` → ticks, `true/false`, `null`, string | ✓ |
| `if / elseif / else` | | ✓ |
| `while … do … end` | op-budget-bounded | ✓ |
| Numeric `for` | `for i = a, b[, step] do` | ✓ |
| `for_each_unit_in` | iterate a `group`, ascending id (§7) | ✓ |
| `break` / `return` | | ✓ |
| User function def | `function f(a: T, …) -> R … end`; recursion allowed (depth-capped) | ✓ |
| Function call | `f(args)` | ✓ |
| Event handler | `on <event>(params) … end` — registers on an event (§5) | ✓ |
| `wait(duration)` | tick-scheduled continuation; suspends the frame, hashed (§3.7) | ✓ |
| Per-instance data | locals captured by a started timer/effect, read in its callback — the **MUI** mechanism (§3.2) | ✓ |
| `comment` | `-- …` | ✓ |

**Op budget / call-depth caps** are enforced by the VM, not authored (§3.7).


## 3. Events

What can fire a trigger (`Event`). The handler runs its conditions then actions
(design_m5.md §3.7); event-context queries (§4) read the event's subject.

| Event | Fires when | Slice |
|---|---|---|
| `match_start` | the match begins (after spawn) | ✓ |
| `map_init` | once, before `match_start`, for setup | ◐ |
| `every(duration)` | periodically (repeating timer sugar) | ✓ |
| `timer_expires(timer)` | a specific timer elapses | ✓ |
| `unit_enters_region(region[, filter])` | a unit enters a region | ✓ |
| `unit_leaves_region(region[, filter])` | a unit leaves a region | ✓ |
| `unit_dies([filter])` | a unit/structure dies | ✓ |
| `structure_completes([filter])` | a GROWING structure finishes (game-specific) | ✓ |
| `unit_created([filter])` | a unit is spawned/trained | ◐ |
| `unit_takes_damage([filter])` | a unit is damaged (source/amount in context) | ◐ |
| `player_resource_crosses(player, resource, value, dir)` | resource passes a threshold | ◐ |
| `ability_cast([filter])` | a unit uses an ability (caster/target in context) | ◐ |
| `unit_attacked([filter])` | a unit acquires/begins attacking | ○ |
| `unit_enters_range(unit, radius)` | something enters a unit's radius | ○ |
| `player_eliminated(player)` | a player meets the defeat condition (§7) | ◐ |

Region-count change ("when N units are in R") is expressed as `every(…)` + a
count query (§7) for the slice; a dedicated event is `○`.


## 4. Event-context queries

Within a handler, read the event's subject (`Query`). Returning `null` outside a
matching event is a compile-time misuse where detectable, else a runtime `null`.

| Query | Returns | Slice |
|---|---|---|
| `triggering_unit()` | `unit` | ✓ |
| `triggering_player()` | `player` | ✓ |
| `triggering_region()` | `region` | ✓ |
| `entering_unit()` / `leaving_unit()` | `unit` | ✓ |
| `dying_unit()` / `killing_unit()` | `unit` | ✓ |
| `completed_structure()` | `unit` | ✓ |
| `created_unit()` | `unit` | ◐ |
| `damaged_unit()` / `damage_source()` / `damage_amount()` | `unit` / `unit` / `int` | ◐ |
| `casting_unit()` / `cast_target_unit()` / `cast_target_point()` | `unit` / `unit?` / `point?` | ◐ |
| `expired_timer()` | `timer` | ✓ |


## 5. Query library — read-only sim state

All `Query` (pure, hashable inputs). Grouped by domain.

### 5.1 Entity state

| Query | Returns | Slice |
|---|---|---|
| `unit_type(u)` | `unittype` | ✓ |
| `owner(u)` | `player` | ✓ |
| `is_alive(u)` | `bool` | ✓ |
| `unit_hp(u)` / `unit_max_hp(u)` | `int` | ✓ |
| `unit_position(u)` | `point` | ✓ |
| `is_structure(u)` / `is_unit(u)` | `bool` | ✓ |
| `build_state(u)` | `build_state` enum | ◐ |
| `unit_stance(u)` | `stance` | ◐ |
| `has_ability(u, abilitytype)` | `bool` | ◐ |
| `unit_facing(u)` | `fixed` (angle) | ○ |
| `carried_resource(u)` / `carried_amount(u)` | `resource?` / `int` (worker, game-specific) | ○ |
| `is_hidden(u)` | `bool` (burrowed/underground) | ○ |

### 5.2 Geometry

| Query | Returns | Slice |
|---|---|---|
| `point(x, y)` | `point` | ✓ |
| `point_x(p)` / `point_y(p)` | `fixed` | ✓ |
| `offset(p, dx, dy)` | `point` | ✓ |
| `distance(a, b)` | `fixed` (point/point, unit/unit, unit/point) | ✓ |
| `region_center(r)` | `point` | ✓ |
| `region_random_point(r)` | `point` (DRng) | ✓ |
| `point_in_region(p, r)` | `bool` | ✓ |
| `unit_in_region(u, r)` | `bool` | ✓ |
| `polar_offset(p, dist, angle)` | `point` | ○ |
| `angle_between(a, b)` | `fixed` | ○ |

### 5.3 Groups

| Query / op | Returns | Slice |
|---|---|---|
| `units_in_region(r, filter)` | `group` | ✓ |
| `units_of_player(p, filter)` | `group` | ✓ |
| `units_in_range(p, radius, filter)` | `group` | ✓ |
| `units_of_type(t, filter)` | `group` | ◐ |
| `group_size(g)` | `int` | ✓ |
| `group_contains(g, u)` | `bool` | ✓ |
| `random_unit_in(g)` | `unit?` (DRng) | ✓ |
| `nearest_unit(p, filter)` | `unit?` | ✓ |
| `first_unit_in(g)` | `unit?` | ◐ |
| `group_add(g, u)` / `group_remove(g, u)` / `group_clear(g)` | mutate (Action) | ✓ |

### 5.4 Players & economy

| Query | Returns | Slice |
|---|---|---|
| `player_resource(p, resource)` | `int` | ✓ |
| `player_supply_used(p)` / `player_supply_cap(p)` | `int` | ◐ |
| `player_unit_count(p, filter)` | `int` | ✓ |
| `is_enemy(a, b)` / `is_ally(a, b)` | `bool` (player relation) | ✓ |
| `player_relation(a, b)` | `relation` enum | ◐ |

### 5.5 Vision (sim-side fog)

| Query | Returns | Slice |
|---|---|---|
| `is_visible_to(p, target)` | `bool` (point or unit, against player fog) | ◐ |
| `is_explored(p, point)` | `bool` | ○ |


## 6. Action library — sim mutations

All `Action` (hashed). The **command-source bridge** (§6.3) reuses the player's
`SimCommand` validation; **god actions** (free spawn, set-resource, runtime
edits) are trigger-origin-only (design_m5.md §3.5).

### 6.1 Units (god / direct)

| Action | Slice |
|---|---|
| `create_unit(unittype, player, point[, facing]) -> unit` | ✓ |
| `create_units(count, unittype, player, point) -> group` | ✓ |
| `remove_unit(u)` (silent, no death event) | ✓ |
| `kill_unit(u)` (fires `unit_dies`) | ✓ |
| `damage_unit(target, amount[, source, attack_class])` | ✓ |
| `heal_unit(u, amount)` | ✓ |
| `set_unit_hp(u, hp)` | ◐ |
| `set_unit_position(u, point)` (teleport) | ◐ |
| `set_owner(u, player)` | ◐ |
| `set_unit_stance(u, stance)` | ◐ |
| `pause_unit(u, bool)` (cinematic freeze) | ◐ |
| `add_ability(u, abilitytype)` / `remove_ability(u, abilitytype)` | ○ |
| `set_unit_facing(u, angle)` | ○ |

### 6.2 Structures & economy (god)

| Action | Slice |
|---|---|
| `set_resource(player, resource, amount)` | ✓ |
| `add_resource(player, resource, amount)` | ✓ |
| `set_construction_progress(u, fixed)` | ○ |
| `set_supply_bonus(player, int)` | ○ |

### 6.3 Orders (the SimCommand bridge — player-equivalent)

Issue the orders a human could; `unit | group` target. Used heavily for
scenario AI (design_m5.md §3.5).

| Action | Slice |
|---|---|
| `order_move(target, point)` | ✓ |
| `order_attack(target, enemy_unit)` | ✓ |
| `order_attack_move(target, point)` | ✓ |
| `order_patrol(target, point)` | ✓ |
| `order_stop(target)` / `order_hold(target)` | ✓ |
| `order_ability(target, abilitytype[, point | unit])` | ◐ |
| `order_build(worker, structtype, point)` | ◐ |
| `order_mine(worker, node)` | ○ |
| `order_train(structure, unittype)` | ◐ |
| `set_rally(structure, point)` | ◐ |

### 6.4 Regions

| Action | Slice |
|---|---|
| `move_region(r, point)` | ◐ |
| `resize_region(r, w, h)` | ○ |
| `create_region(rect) -> region` (runtime) | ○ |

### 6.5 Vision / fog

| Action | Slice |
|---|---|
| `reveal(player, area[, duration])` (point+radius or region) | ◐ |
| `unreveal(player, area)` | ◐ |

### 6.6 Variables, groups, timers

| Action | Slice |
|---|---|
| group mutation (`group_add/remove/clear`, §5.3) | ✓ |
| `start_timer(duration, repeating, callback[, instance_data]) -> timer` | ✓ |
| `pause_timer(t)` / `resume_timer(t)` / `destroy_timer(t)` | ◐ |
| `timer_remaining(t) -> fixed` (Query) | ◐ |

### 6.7 Trigger control

| Action | Slice |
|---|---|
| `enable_trigger(tr)` / `disable_trigger(tr)` | ✓ |
| `run_trigger(tr[, check_conditions])` | ◐ |
| `is_trigger_enabled(tr) -> bool` (Query) | ◐ |
| `destroy_trigger(tr)` (dynamic) | ○ |

### 6.8 Match control

| Action | Slice |
|---|---|
| `declare_victory(player)` / `declare_defeat(player)` | ✓ |
| `end_match(winner_player)` | ✓ |
| `set_player_eliminated(player, bool)` | ◐ |

### 6.9 Runtime catalog edits (god, powerful)

| Action | Slice |
|---|---|
| `set_unit_field(u, field, value)` (per-instance stat override) | ○ |
| `set_catalog_field(type, field, value)` (player/global upgrade-style) | ○ |

These overlap the upgrade/tech-tree feature space and are deferred until a target
map needs them (a wave-scaling TD can use stronger *types* or `set_unit_hp`
instead). Flagged so the registry has a home for them.


## 7. Presentation library

All `Pres` — emitted to the view's unhashed event queue (design_m5.md §3.4),
never sim state. Cosmetic-only; safe to differ per client.

| Action | Slice |
|---|---|
| `display_message(who, string[, duration])` (`who` = player / all) | ✓ |
| `clear_messages(who)` | ◐ |
| `ping_minimap(who, point[, color, duration])` | ✓ |
| `camera_pan(player, point, duration)` | ◐ |
| `camera_lock(player, unit)` / `camera_reset(player)` | ◐ |
| `cinematic_mode(player, bool)` (letterbox, hide UI) | ◐ |
| `screen_fade(player, color, duration)` | ◐ |
| `transmission(player, unit?, string, duration)` (text + optional speaker) | ◐ |
| `play_sound(who, soundref)` | ○ (needs custom assets / a built-in sound set — out of scope v1) |
| `create_floating_text(point, string)` | ○ (design.md: phone-screen noise, deliberately out) |


## 8. Constants & enums

| Enum / constant | Values |
|---|---|
| players | `PLAYER_1`, `PLAYER_2`, …, `NEUTRAL` (player 0); plus event-context `triggering_player()` |
| `resource` | `ALLOY`, `FLUX` |
| `stance` | `DEFENSIVE`, `BALANCED`, `RECKLESS`, `SKIRMISH` |
| `relation` | `ENEMY`, `ALLY`, `SELF` |
| `build_state` | `CAPSULE`, `GROWING`, `COMPLETE` |
| compare dir | `RISES_ABOVE`, `FALLS_BELOW` (threshold events) |
| filters | `ENEMY_OF(player)`, `ALLY_OF(player)`, `OWNED_BY(player)`, `OF_TYPE(t)`, `ALIVE`, `IS_STRUCTURE`, `IS_UNIT`, `ANY`, or a user `fn(unit)->bool` |
| color | named UI colors for pings/messages (presentation) |
| `true` / `false` / `null` | |


## 9. Math / core functions

| Function | Returns | Slice |
|---|---|---|
| `min(a,b)` / `max(a,b)` / `abs(a)` / `clamp(x,lo,hi)` | numeric | ✓ |
| `random_int(lo, hi)` | `int` (DRng) | ✓ |
| `random_fixed(lo, hi)` | `fixed` (DRng) | ◐ |
| `to_fixed(i)` / `floor(f)` / `round(f)` | conversions | ◐ |


## 10. Filters

Group queries (§5.3) and some events (§3) take a **filter**. Two forms:

- **Built-in filter constants** (§8) — composable: `ENEMY_OF(PLAYER_1) and ALIVE`.
- **User predicate** — `fn(unit) -> bool`, evaluated per candidate (counts
  against the op budget). Deterministic: candidates are visited ascending id.

The slice ships the built-in constants (`✓`); the user-predicate form is `◐`
(it falls out of having user functions, but wants an op-budget guard).


## 11. Target-map coverage — what the M5 slice must contain

The slice is the **union of what these three maps need** (design_m5.md §3.10).
Each clusters the catalog above; enumerate-then-implement before coding (§12).

| Cluster | Tower defense | Scripted-AI melee | Cinematic intro |
|---|---|---|---|
| Events: `match_start`, `every`, `timer_expires`, region enter/leave, `unit_dies` | ● | ● | ● (`match_start`) |
| Event-context (`triggering/entering/dying_unit`, `expired_timer`) | ● | ● | ◐ |
| Variables/locals, arithmetic, comparison, control flow, functions | ● | ● | ● |
| `wait` + per-instance data (MUI) | ● (DoT/effects) | ◐ | ● (timed beats) |
| Geometry + groups + filters (`units_in_region`, `nearest_unit`, `for_each`) | ● | ● | ◐ |
| Unit actions (`create_unit(s)`, `kill_unit`, `damage_unit`) | ● | ● | ◐ (`create_unit`) |
| Order bridge (`order_attack_move`, `move`, `attack`, `patrol`, `stop/hold`) | ● (leak path) | ● (AI waves) | ◐ |
| Economy (`set/add_resource`, `player_resource`) | ◐ (lives as resource?) | ● | ○ |
| Match control (`declare_victory/defeat`, `end_match`) | ● | ● | ○ |
| Presentation (`display_message`, `ping_minimap`) | ● | ◐ | ● (+ camera, fade, transmission, cinematic_mode) |
| Vision (`reveal`/`is_visible_to`) | ○ | ◐ | ◐ |

`●` = central to that map · `◐` = used · `○` = not needed. The `✓`/`◐` Slice
marks throughout this doc are derived from this matrix.


## 12. Open questions (catalog-specific)

Feed back into design_m5.md §9.

1. **Freeze the slice.** Turn the `✓`/`◐` marks into a final, enumerated M5
   function list before implementation (design_m5.md §9 Q1). The `◐`s are the
   debate; the `✓`s are settled.
2. **Filters: constants vs user predicates in M5.** Built-in constants are `✓`;
   shipping user-predicate filters in M5 depends on op-budget guarding (§10).
3. **Order targets: single unit vs group ergonomics.** Should every `order_*`
   accept both `unit` and `group` uniformly (implies overloading or a `target`
   sum type)? Affects the type system (§1).
4. **`damage_unit` and the class matrix.** Does trigger damage take an
   `attack_class` (routing through the M3 §2.6 matrix) or apply flat? Pick one;
   flat is simpler, classed is consistent with combat.
5. **Runtime catalog edits / upgrades** (§6.9) — the biggest deferred cluster.
   Decide when a target map (a real tech-tree mode) forces it; until then,
   stronger *types* + `set_unit_hp` cover wave scaling.
6. **Sound without assets** (§7) — `play_sound` needs either custom assets (out
   of scope v1) or a small built-in sound set. Decide if v1 ships a built-in set
   for the cinematic map, or defers audio entirely (consistent with M4's audio
   deferral).
7. **Naming pass.** Function names here are Lua-flavored placeholders; a single
   consistent naming convention (verb_noun, argument order) should be locked with
   the language spec/docs (design_m5.md §3.9) since it's the authoring surface.
