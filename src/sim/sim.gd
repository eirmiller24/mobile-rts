class_name Sim
extends RefCounted
## The deterministic game simulation. Headless, tick-driven, fixed-point.
##
## Constitution (see design.md "Determinism rules"):
##  - No floats, no engine physics, no node access, no wall-clock time.
##  - All randomness comes from `rng`.
##  - All iteration over entities happens in ascending entity-id order.
##  - The only inputs are the seed at construction and scheduled commands.
##
## The view layer reads sim state to render it but never writes back.

const TICK_RATE := 20
## Commands are scheduled this many ticks after issue (lockstep latency).
const COMMAND_DELAY := 3

var tick: int = 0
var rng: DRng
## entity_id -> Dictionary entity record. Placeholder representation until
## the entity/component design lands in M2.
var entities: Dictionary = {}

var _next_entity_id: int = 1
## tick -> Array[SimCommand]
var _command_queue: Dictionary = {}


func _init(seed_value: int) -> void:
	rng = DRng.new(seed_value)


## Schedule a command for execution. Lockstep peers must schedule identical
## commands for identical ticks.
func schedule(cmd: SimCommand, at_tick: int = -1) -> void:
	var t := at_tick if at_tick >= 0 else tick + COMMAND_DELAY
	assert(t >= tick, "cannot schedule a command in the past")
	if not _command_queue.has(t):
		_command_queue[t] = []
	_command_queue[t].append(cmd)


## Advance the sim by exactly one tick.
func step() -> void:
	_execute_scheduled_commands()
	_update_systems()
	tick += 1


func spawn_entity(record: Dictionary) -> int:
	var id := _next_entity_id
	_next_entity_id += 1
	entities[id] = record
	return id


## Order-insensitive inputs are sorted so every peer executes identically.
func _execute_scheduled_commands() -> void:
	if not _command_queue.has(tick):
		return
	var commands: Array = _command_queue[tick]
	_command_queue.erase(tick)
	commands.sort_custom(func(a: SimCommand, b: SimCommand) -> bool:
		if a.player_id != b.player_id:
			return a.player_id < b.player_id
		return a.seq < b.seq)
	for cmd in commands:
		_execute(cmd)


func _execute(cmd: SimCommand) -> void:
	match cmd.kind:
		SimCommand.Kind.DEBUG_SPAWN:
			spawn_entity({
				"player": cmd.player_id,
				"pos_x": cmd.params.get("x", 0),
				"pos_y": cmd.params.get("y", 0),
			})
		_:
			pass # Systems land in M2/M3.


func _update_systems() -> void:
	pass # Movement, combat, economy systems land in M2/M3.


## Cheap rolling hash over sim state for lockstep desync detection.
func state_hash() -> int:
	var h := 17
	h = (h * 31 + tick) & 0x7FFFFFFFFFFFFFF
	h = (h * 31 + rng.state) & 0x7FFFFFFFFFFFFFF
	h = (h * 31 + _next_entity_id) & 0x7FFFFFFFFFFFFFF
	var ids := entities.keys()
	ids.sort()
	for id in ids:
		h = (h * 31 + id) & 0x7FFFFFFFFFFFFFF
		var record: Dictionary = entities[id]
		var keys := record.keys()
		keys.sort()
		for key in keys:
			var value = record[key]
			assert(typeof(value) != TYPE_FLOAT, "float leaked into sim state")
			h = (h * 31 + hash(key)) & 0x7FFFFFFFFFFFFFF
			h = (h * 31 + hash(value)) & 0x7FFFFFFFFFFFFFF
	return h
