class_name SimEntity
extends RefCounted
## One sim entity: a mobile unit (round collision) or a structure (square
## footprint of blocked pathing cells). Plain data advanced by Sim's
## systems — no nodes, no floats, every field folded into hash_into().

enum Kind { UNIT, STRUCTURE, RESOURCE }

var id: int = 0
var player: int = 0
var kind := Kind.UNIT
## Catalog type this entity was spawned from (CompiledCatalog type_key).
var type_key: int = -1

## Center position, fixed-point world units.
var x: int = 0
var y: int = 0
## Collision radius (units only), fixed-point.
var radius: int = 0
## Movement per tick, fixed-point (stats give speed/sec; Sim divides).
var step: int = 0

var hp: int = 0
var max_hp: int = 0
## Untargetable entities (resource nodes, scenery) block movement but are
## never acquired or attacked.
var targetable: bool = true
## Attack stats. damage == 0 means the entity never fights.
var damage: int = 0
var attack_range: int = 0   # fixed, edge-to-edge
var acquire_range: int = 0  # fixed, center-to-center
var cooldown_ticks: int = 0
var cooldown: int = 0
## Crit proc parameters, fixed-point fractions (0 = no crit).
var crit_base: int = 0
var crit_bonus: int = 0
## Proc name -> consecutive-failure stacks (see ProcRng).
var procs: Dictionary = {}
## Vision radius, fixed (tiles = world units). 0 = projects no sight.
var sight: int = 0
## Can attack airborne targets (capsules). Melee authors false.
var hits_air: bool = false
## Interned damage/armor class indices (-1 = unset; no multiplier).
var attack_class: int = -1
var armor_class: int = -1
## Base incoming-damage multiplier, fixed. Hive structures author 1.5 (the
## feral state); the influence aura restores 1.0 (design_m3.md §4.3).
var damage_taken: int = Fixed.ONE

## Resource nodes (kind RESOURCE): remaining amount (fixed — extraction is
## fractional per tick) and CatalogSchema.ResourceKind.
var amount: int = 0
var resource_kind: int = -1

var target_id: int = 0

## Order queue; front is the active order. Each order is a Dictionary:
## {"kind": SimCommand.Kind, "x": fixed, "y": fixed, "small": bool}.
## Viewport orders replace the queue; queued console orders append.
var orders: Array[Dictionary] = []
## Flow-field cache key (goal cell index) of the active move order.
var goal_key: int = -1
## Goal key of the last completed order — lets crowd-arrival propagate
## ("I'm touching someone who already arrived at my goal, so I'm done").
var done_goal_key: int = -1
## A* path (cell indices) for small orders; empty means follow the flow field.
var path := PackedInt32Array()
var path_i: int = 0
## Anti-deadlock progress tracking for the active move order: best squared
## distance to the goal so far, and ticks since it last improved. A unit
## stalled for STALL_TICKS while touching an arrived group-mate completes
## where it stands (see Sim._arrived_neighbor).
var goal_d2_best: int = 0
var stall: int = 0

## Structure footprint in pathing cells.
var foot_x: int = 0
var foot_y: int = 0
var foot_w: int = 0
var foot_h: int = 0
## Whether this entity currently blocks its footprint on the grid
## (capsules don't; everything else with a footprint does).
var blocks: bool = false

## Structure lifecycle (design_m3.md §4.5). Units and resources are
## always COMPLETE. build_ticks_left is FIXED ticks in both timed states:
## the capsule countdown while CAPSULE, remaining growth while GROWING
## (fixed so fractional assist-nano progress accrues exactly).
enum BuildState { CAPSULE, GROWING, COMPLETE }
var build_state := BuildState.COMPLETE
var build_ticks_left: int = 0
## Assist-nano bonus progress granted this tick (fixed ticks); consumed
## and reset by the structures phase the same tick.
var assist_bonus: int = 0
## Fractional healing accumulator (fixed hp) for regen + repair.
var heal_acc: int = 0
## Siphon -> the vent entity it extracts from (0 = none).
var vent_id: int = 0
## Stronghold nanomachine allocation: [alloy, flux, assist] (sum <= the
## catalog nano_pool; the remainder idles).
var nano_alloc: Array[int] = [0, 0, 0]

## Production (design_m3.md §4.7): queued trainees [{type: type_key,
## left: int ticks}], head builds; rally point (0,0 sentinel = unset).
var train_queue: Array[Dictionary] = []
var rally_x: int = 0
var rally_y: int = 0

## Commanded abilities (design_m3.md §4.8). morph_ticks_left > 0 =
## mid-transition (immobile, can't act); `morphed` = the toggled form's
## stat overrides are applied. underground_ticks_left > 0 = burrowing
## (no collision, untargetable, surfaces at surface_x/y when it hits 0).
var morphed: bool = false
var morph_ticks_left: int = 0
var underground_ticks_left: int = 0
var surface_x: int = 0
var surface_y: int = 0
## ability type_key (int) -> ticks until ready again.
var ability_cooldowns: Dictionary = {}

## M4 worker harvest economy (design_m4.md §3). The loop is a small state
## machine stored in hashed entity fields; carry is fixed-point resource
## units of carry_kind. work_state is the per-worker truth the Economy slider
## is a window onto (§3.2): the four auto-pool states plus MANUAL (out of the
## economy, an ordinary commandable unit). _BUILD variants mine but are
## draftable to build/wall/repair. Replaces the old harvest_role dial.
enum HarvestState { IDLE, TO_SOURCE, HARVESTING, TO_DEPOT, DEPOSITING }
enum WorkState { ALLOY, ALLOY_BUILD, FLUX, FLUX_BUILD, MANUAL }
var harvest_state := HarvestState.IDLE
var carry: int = 0          # fixed
var carry_kind: int = -1    # CatalogSchema.ResourceKind; -1 = empty
var assigned_source: int = 0  # source entity id (deposit / vent / refinery)
var work_state := WorkState.ALLOY
## The stronghold/depot this worker belongs to (design_m4.md §3.2 playtest):
## auto-mining stays within AUTO_MINE_RADIUS of it, so workers stick to their own
## base and count toward its replenish target. 0 = unassigned (set to the nearest
## depot on the next economy tick). Sticky until that depot dies or a MINE order
## moves the worker to another base's region. (Carry deposits at the *nearest*
## depot — alloy/flux is one shared player pool, so deposit is just a walk.)
var home_depot: int = 0

## M4 per-stronghold worker economy (design_m4.md §3.2 playtest). On a depot
## structure these are the economy TARGET for that base, independent of how many
## workers are currently alive (so deaths don't change the plan): keep
## worker_target workers, of which eco_alloy mine Alloy (eco_alloy_build of those
## draftable to build/repair) and the rest mine Flux (eco_flux_build draftable).
## Auto-replace refills toward this, the slider edits it, and it persists through
## losses. All 0 on non-depot entities.
var worker_target: int = 0
var eco_alloy: int = 0
var eco_alloy_build: int = 0
var eco_flux_build: int = 0


## Mining side of a work_state: ALLOY (1) / FLUX (2), or 0 for MANUAL.
func mine_role() -> int:
	match work_state:
		WorkState.ALLOY, WorkState.ALLOY_BUILD:
			return 1
		WorkState.FLUX, WorkState.FLUX_BUILD:
			return 2
		_:
			return 0


## Draftable to build/wall/repair (an _BUILD auto-pool state).
func build_draftable() -> bool:
	return work_state == WorkState.ALLOY_BUILD \
			or work_state == WorkState.FLUX_BUILD


func is_manual_worker() -> bool:
	return work_state == WorkState.MANUAL

## M4 worker build (design_m4.md §4). build_target is the GROWING structure
## this worker is raising/repairing; >0 means BUILDING (immobile on site).
var build_target: int = 0
## Drawn-wall segment cell this worker is walking to raise (§4.4); -1 none.
var wall_target_cell: int = -1
## M4 (design_m4.md §4.1): a worker-built structure spawns GROWING but
## frozen until a worker is on site. The Hive's instant path leaves it false.
var needs_builder: bool = false
## M4 refinery (design_m4.md §3.1): the Flux vents an is_refinery structure
## auto-linked at COMPLETE, ascending id. Compiled, not authored.
var linked_vents := PackedInt32Array()

## M4 unit AI (design_m4.md §9). stance + priority-flag bitfield; anchor is
## the defensive hold point (anchor_set guards the 0,0 sentinel ambiguity).
var stance: int = 0         # CatalogSchema.Stance
var tactic_flags: int = 0   # CatalogSchema.TacticFlag bitfield
var anchor_x: int = 0
var anchor_y: int = 0
var anchor_set: bool = false


func is_underground() -> bool:
	return underground_ticks_left > 0


func is_unit() -> bool:
	return kind == Kind.UNIT


func is_resource() -> bool:
	return kind == Kind.RESOURCE


## Airborne (a flying capsule): only attackers with hits_air can hit it.
func is_aerial() -> bool:
	return kind == Kind.STRUCTURE and build_state == BuildState.CAPSULE


func hash_into(h: int) -> int:
	for v: int in [id, player, kind, type_key, x, y, radius, step, hp, max_hp,
			int(targetable), damage, attack_range, acquire_range,
			cooldown_ticks, cooldown, crit_base, crit_bonus, target_id,
			sight, int(hits_air), attack_class, armor_class, damage_taken,
			amount, resource_kind,
			goal_key, done_goal_key, path_i, goal_d2_best, stall,
			foot_x, foot_y, foot_w, foot_h, int(blocks),
			build_state, build_ticks_left, assist_bonus, heal_acc, vent_id,
			nano_alloc[0], nano_alloc[1], nano_alloc[2],
			rally_x, rally_y, int(morphed), morph_ticks_left,
			underground_ticks_left, surface_x, surface_y,
			harvest_state, carry, carry_kind, assigned_source, work_state,
			home_depot, worker_target, eco_alloy, eco_alloy_build, eco_flux_build,
			build_target, wall_target_cell, int(needs_builder),
			stance, tactic_flags, anchor_x, anchor_y, int(anchor_set)]:
		h = (h * 31 + v) & 0x7FFFFFFFFFFFFFF
	for vent in linked_vents:
		h = (h * 31 + vent) & 0x7FFFFFFFFFFFFFF
	for q in train_queue:
		h = (h * 31 + q["type"]) & 0x7FFFFFFFFFFFFFF
		h = (h * 31 + q["left"]) & 0x7FFFFFFFFFFFFFF
		h = (h * 31 + q.get("replace_depot", 0)) & 0x7FFFFFFFFFFFFFF
	var cd_keys := ability_cooldowns.keys()
	cd_keys.sort()
	for key in cd_keys:
		h = (h * 31 + key) & 0x7FFFFFFFFFFFFFF
		h = (h * 31 + ability_cooldowns[key]) & 0x7FFFFFFFFFFFFFF
	var proc_keys := procs.keys()
	proc_keys.sort()
	for key in proc_keys:
		h = (h * 31 + SimHash.fnv_string(key)) & 0x7FFFFFFFFFFFFFF
		h = (h * 31 + procs[key]) & 0x7FFFFFFFFFFFFFF
	for o in orders:
		h = (h * 31 + o["kind"]) & 0x7FFFFFFFFFFFFFF
		h = (h * 31 + o["x"]) & 0x7FFFFFFFFFFFFFF
		h = (h * 31 + o["y"]) & 0x7FFFFFFFFFFFFFF
	for c in path:
		h = (h * 31 + c) & 0x7FFFFFFFFFFFFFF
	return h
