class_name SimCommand
extends RefCounted
## A player intent fed into the sim. Commands are the ONLY input the sim
## accepts after construction — this is what goes over the wire in lockstep.
##
## Positions and other spatial params are fixed-point (see Fixed); never put
## floats in a command.

enum Kind {
	MOVE,
	ATTACK_MOVE,
	PATROL,
	STOP,
	BUILD,
	ABILITY,
	SET_TACTIC,
	ALLOCATE_ECONOMY,
	DEBUG_SPAWN,
	TRAIN,
	CANCEL,
	SET_RALLY,
	## M4 (design_m4.md §12). Appended so existing ordinals are unchanged.
	MINE,          # [worker_ids] node — manual harvest; nudges economy dials
	SET_ECONOMY,   # [player-scope] worker_target/ratios/auto_repair dials
	BUILD_WALL,    # [player-scope] cells — drawn-wall segment queue (§4.4)
	REPAIR,        # [worker_ids] target — worker repairs own structure
}

var player_id: int
var kind: Kind
## Entity ids this command applies to, sorted ascending for determinism.
var targets: Array[int] = []
## Kind-specific payload (fixed-point coords, catalog ids, etc).
var params: Dictionary = {}
## Per-player sequence number; with player_id forms a total order for
## commands scheduled on the same tick.
var seq: int = 0


func _init(p_player_id: int = 0, p_kind: Kind = Kind.STOP) -> void:
	player_id = p_player_id
	kind = p_kind


## Stable contribution to the sim state hash.
func hash_into(h: int) -> int:
	h = (h * 31 + player_id) & 0x7FFFFFFFFFFFFFF
	h = (h * 31 + kind) & 0x7FFFFFFFFFFFFFF
	h = (h * 31 + seq) & 0x7FFFFFFFFFFFFFF
	for t in targets:
		h = (h * 31 + t) & 0x7FFFFFFFFFFFFFF
	return h
