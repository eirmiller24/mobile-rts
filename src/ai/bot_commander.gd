class_name BotCommander
extends RefCounted
## A scripted opponent built as a *command source* outside the sim wall
## (design_m4.md §8): it reads sim state through the same read-only view the
## UI uses and emits ordinary SimCommands through `sim.schedule` — every bot
## action is a command a human could issue. It is deliberately competent, not
## clever (a strong AI is post-M7).
##
## Both factions are driven by this one class, generically off the catalog:
## it never names "Stronghold" or "HQ", only the catalog facts (trains a
## worker, provides bandwidth, is_main, has a build ability). It runs at human
## cadence (every THINK_PERIOD ticks) and owns its own RNG outside the wall.
##
## Its commands enter the scheduled stream, so replays/lockstep reproduce the
## bot exactly from the recorded stream regardless of its internal RNG.

const THINK_PERIOD := 10
## Train combat units up to this army size, then push out to attack.
const ARMY_ATTACK_THRESHOLD := 6
const ARMY_RETREAT_THRESHOLD := 2
## Build supply once used Crew/Bandwidth reaches this fraction of provided.
const SUPPLY_HEADROOM := 2

var sim: Sim
var player_id: int
var rng := RandomNumberGenerator.new()
var _seq := 0
## Recorded (at_tick, command) stream — a replay re-runs exactly this.
var issued: Array[Dictionary] = []
## Remembered enemy structure positions (fog-honest targeting): id -> [x, y].
var _seen_enemy: Dictionary = {}
## Enemy start locations [[x, y], ...] the match setup hands the bot to scout
## toward before it has seen anything (RTS bots know start positions). The
## army commits to a hint and discovers the truth on arrival (§6.4 semantics).
var scout_hints: Array = []


func _init(p_sim: Sim, p_player_id: int, seed_value: int) -> void:
	sim = p_sim
	player_id = p_player_id
	rng.seed = seed_value


## Call every tick; acts only on its think cadence.
func tick() -> void:
	if sim.tick % THINK_PERIOD != 0:
		return
	if sim.players.get(player_id) == null \
			or sim.players[player_id].eliminated_tick != -1:
		return
	_update_memory()
	_economy()
	_supply()
	_produce()
	_command_army()


# --- command plumbing ---------------------------------------------------------


func _issue(kind: SimCommand.Kind, targets: Array[int], params: Dictionary) -> void:
	var c := SimCommand.new(player_id, kind)
	c.targets = targets
	c.params = params
	c.seq = _seq
	_seq += 1
	var at := sim.tick + Sim.COMMAND_DELAY
	sim.schedule(c, at)
	issued.append({"at": at, "cmd": c})


# --- reads --------------------------------------------------------------------


func _own(filter: Callable) -> Array[SimEntity]:
	var out: Array[SimEntity] = []
	for id in sim._sorted_ids():
		var e: SimEntity = sim.entities[id]
		if e.player == player_id and e.hp > 0 and filter.call(e):
			out.append(e)
	return out


func _is_combat_unit(e: SimEntity) -> bool:
	if not e.is_unit():
		return false
	var s := sim.catalog.sim_of(e.type_key)
	return s["damage"] > 0 and s["carry_capacity"] == 0


func _is_worker_type(type: int) -> bool:
	return sim.catalog.sim_of(type)["carry_capacity"] > 0


func _update_memory() -> void:
	# Remember any enemy structure we can currently see (design_m4.md §6.4:
	# act on knowledge, not ground truth).
	for id in sim.entities:
		var e: SimEntity = sim.entities[id]
		if e.kind != SimEntity.Kind.STRUCTURE or e.player == player_id \
				or e.player == 0:
			continue
		if sim.is_entity_visible(player_id, e):
			_seen_enemy[id] = [e.x, e.y, sim.catalog.sim_of(e.type_key).get("is_main", false)]
		elif _seen_enemy.has(id) and not sim.entities.has(id):
			_seen_enemy.erase(id)


# --- economy ------------------------------------------------------------------


func _economy() -> void:
	# Rebel-style economy: drive EACH stronghold's worker dials (per-depot now,
	# design_m4.md §3.2 playtest) and let auto-replace keep them staffed. Aim
	# ~6 alloy / 2 flux per base, one alloy worker draftable to build.
	var depots := _own(_is_depot_filter)
	for d in depots:
		_issue(SimCommand.Kind.SET_ECONOMY, [d.id], {
			"worker_target": 8,
			"alloy_side": 6,
			"alloy_build": 1,
			"flux_build": 0,
		})
	if not depots.is_empty():
		_issue(SimCommand.Kind.SET_ECONOMY, [], {"auto_repair": true})
	# Hive-style economy needs no command: strongholds default to mining alloy.


func _is_worker_filter(e: SimEntity) -> bool:
	return e.is_unit() and sim.catalog.sim_of(e.type_key)["carry_capacity"] > 0


func _is_depot_filter(e: SimEntity) -> bool:
	return e.kind == SimEntity.Kind.STRUCTURE \
			and sim.catalog.sim_of(e.type_key).get("is_depot", false)


# --- supply -------------------------------------------------------------------


func _supply() -> void:
	var bw := sim.bandwidth_of(player_id)
	if bw["provided"] - bw["used"] > SUPPLY_HEADROOM:
		return
	# Find a buildable supply structure (provides bandwidth, no attack/nano).
	var best := -1
	for type: int in sim.buildable_structures(player_id):
		var s := sim.catalog.sim_of(type)
		if s["bandwidth_provided"] > 0 and s["nano_pool"] == 0 and not s["is_main"]:
			if best == -1 or s["cost_alloy"] < sim.catalog.sim_of(best)["cost_alloy"]:
				best = type
	if best == -1:
		return
	_build(best)


# --- production ---------------------------------------------------------------


func _produce() -> void:
	var army := _own(_is_combat_unit)
	if army.size() >= ARMY_ATTACK_THRESHOLD + 4:
		return  # enough in the field; spend elsewhere
	# Train the cheapest affordable combat unit at the shortest-queue producer.
	var res := sim.resources_of(player_id)
	var bw := sim.bandwidth_of(player_id)
	var pick := -1
	for type: int in sim.trainable_units(player_id):
		if _is_worker_type(type):
			continue
		var s := sim.catalog.sim_of(type)
		if s["damage"] <= 0:
			continue
		if res["alloy"] < s["cost_alloy"] or res["flux"] < s["cost_flux"]:
			continue
		if bw["used"] + s["bandwidth"] > bw["provided"]:
			continue
		if pick == -1 or s["cost_alloy"] < sim.catalog.sim_of(pick)["cost_alloy"]:
			pick = type
	if pick == -1:
		return
	var producer := sim.train_structure_for(player_id, pick)
	if producer != 0:
		_issue(SimCommand.Kind.TRAIN, [producer], {"type": pick})


# --- building (capsule or worker) ---------------------------------------------


func _build(type: int) -> void:
	var builder := sim.builder_for(player_id, type)
	if builder == 0:
		return
	# Place near the builder on free, reachable ground.
	var b: SimEntity = sim.entities[builder]
	var s := sim.catalog.sim_of(type)
	var cell := sim._free_cell_near_rect(b.foot_x if b.foot_w > 0 else sim.grid.cell_of(b.x),
			b.foot_y if b.foot_h > 0 else sim.grid.cell_of(b.y),
			maxi(1, b.foot_w), maxi(1, b.foot_h), 8)
	if cell == -1:
		return
	var cx := cell % sim.grid.width
	var cy := cell / sim.grid.width
	if cx + s["foot_w"] > sim.grid.width or cy + s["foot_h"] > sim.grid.height:
		return
	_issue(SimCommand.Kind.BUILD, [builder], {"type": type, "cx": cx, "cy": cy})


# --- aggression / defense -----------------------------------------------------


func _command_army() -> void:
	var army := _own(_is_combat_unit)
	if army.size() < ARMY_ATTACK_THRESHOLD:
		return
	var target := _attack_target()
	if target.is_empty():
		return  # nothing scouted yet; hold and keep massing
	var ids: Array[int] = []
	for e in army:
		ids.append(e.id)
	_issue(SimCommand.Kind.ATTACK_MOVE, ids, {"x": target[0], "y": target[1]})


## Position to attack: a known enemy main if one has been seen, else any known
## enemy structure (fog-honest — from memory, not ground truth). [] if nothing
## is known yet.
func _attack_target() -> Array:
	var any: Array = []
	for id: int in _seen_enemy:
		var rec: Array = _seen_enemy[id]
		any = [rec[0], rec[1]]
		if rec[2]:  # is_main: the win condition — go straight for it
			return [rec[0], rec[1]]
	if not any.is_empty():
		return any
	if not scout_hints.is_empty():
		return [scout_hints[0][0], scout_hints[0][1]]
	return []
