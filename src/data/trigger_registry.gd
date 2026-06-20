class_name TriggerRegistry
extends RefCounted
## The node registry — the trigger language's standard library and the single
## source of truth for its callable vocabulary (design_m5.md §3.3). It drives the
## compiler's typechecker (unknown call = error, wrong arg type = error) here, and
## the C++ VM's dispatch (native/src/sim/trigger_vm.cpp) by matching builtin id.
##
## The integer ids below are the contract: native/src/sim/trigger_ir.h mirrors
## them in `enum BuiltinId`. Add a row here AND a handler+enum there to grow the
## library — never renumber an existing id.
##
## Each builtin: name -> { id, cat, ret, params }
##  cat  : CAT_PURE | CAT_QUERY | CAT_ACTION | CAT_PRES | CAT_CONTEXT
##  ret  : a TriggerIR type (T_VOID for pure-effect actions)
##  params: array of TriggerIR types

const I := preload("res://src/data/trigger_ir.gd")

enum { CAT_PURE = 0, CAT_QUERY = 1, CAT_ACTION = 2, CAT_PRES = 3, CAT_CONTEXT = 4 }

# Filter kinds (mirrored in trigger_vm.cpp). A FILTER value carries {kind, arg}.
enum {
	FK_ANY = 0, FK_ALIVE = 1, FK_IS_STRUCTURE = 2, FK_IS_UNIT = 3,
	FK_ENEMY_OF = 4, FK_ALLY_OF = 5, FK_OWNED_BY = 6, FK_OF_TYPE = 7,
}

# compare-dir + enum constant values (shared with the VM where it matters).
enum { DIR_RISES_ABOVE = 0, DIR_FALLS_BELOW = 1 }

# --- Named constants usable bare in source: name -> [value, type] ---
# Players are slots; NEUTRAL is 0. PLAYER_1.. map to ids 1.. (the map's slots).
const CONSTANTS := {
	"NEUTRAL": [0, I.T_PLAYER],
	"PLAYER_1": [1, I.T_PLAYER],
	"PLAYER_2": [2, I.T_PLAYER],
	"PLAYER_3": [3, I.T_PLAYER],
	"PLAYER_4": [4, I.T_PLAYER],
	# resource enum (matches schema RK_ALLOY=0, RK_FLUX=1)
	"ALLOY": [0, I.T_RESOURCE],
	"FLUX": [1, I.T_RESOURCE],
	# stance enum (matches Entity stance ordinals)
	"DEFENSIVE": [0, I.T_STANCE],
	"BALANCED": [1, I.T_STANCE],
	"RECKLESS": [2, I.T_STANCE],
	"SKIRMISH": [3, I.T_STANCE],
	# relation enum
	"ENEMY": [0, I.T_RELATION],
	"ALLY": [1, I.T_RELATION],
	"SELF": [2, I.T_RELATION],
	# build_state enum
	"CAPSULE": [0, I.T_BUILD_STATE],
	"GROWING": [1, I.T_BUILD_STATE],
	"COMPLETE": [2, I.T_BUILD_STATE],
	# threshold direction
	"RISES_ABOVE": [DIR_RISES_ABOVE, I.T_COMPARE_DIR],
	"FALLS_BELOW": [DIR_FALLS_BELOW, I.T_COMPARE_DIR],
	# zero-arg filter constants
	"ANY": [FK_ANY, I.T_FILTER],
	"ALIVE": [FK_ALIVE, I.T_FILTER],
	"IS_STRUCTURE": [FK_IS_STRUCTURE, I.T_FILTER],
	"IS_UNIT": [FK_IS_UNIT, I.T_FILTER],
}


static func _b(id: int, cat: int, ret: int, params: Array) -> Dictionary:
	return {"id": id, "cat": cat, "ret": ret, "params": params}


## name -> builtin descriptor. Built once (static), the ids are the wire contract.
static func builtins() -> Dictionary:
	return {
		# --- math / core (ids 0-9) ---
		"min": _b(0, CAT_PURE, I.T_INT, [I.T_INT, I.T_INT]),
		"max": _b(1, CAT_PURE, I.T_INT, [I.T_INT, I.T_INT]),
		"abs": _b(2, CAT_PURE, I.T_INT, [I.T_INT]),
		"clamp": _b(3, CAT_PURE, I.T_INT, [I.T_INT, I.T_INT, I.T_INT]),
		"random_int": _b(4, CAT_QUERY, I.T_INT, [I.T_INT, I.T_INT]),
		"to_fixed": _b(5, CAT_PURE, I.T_FIXED, [I.T_INT]),
		"floor": _b(6, CAT_PURE, I.T_INT, [I.T_FIXED]),
		"round": _b(7, CAT_PURE, I.T_INT, [I.T_FIXED]),
		"random_fixed": _b(8, CAT_QUERY, I.T_FIXED, [I.T_FIXED, I.T_FIXED]),

		# --- geometry (ids 10-19) ---
		"point": _b(10, CAT_PURE, I.T_POINT, [I.T_FIXED, I.T_FIXED]),
		"point_x": _b(11, CAT_PURE, I.T_FIXED, [I.T_POINT]),
		"point_y": _b(12, CAT_PURE, I.T_FIXED, [I.T_POINT]),
		"offset": _b(13, CAT_PURE, I.T_POINT, [I.T_POINT, I.T_FIXED, I.T_FIXED]),
		"distance": _b(14, CAT_QUERY, I.T_FIXED, [I.T_POINT, I.T_POINT]),
		"region_center": _b(15, CAT_QUERY, I.T_POINT, [I.T_REGION]),
		"region_random_point": _b(16, CAT_QUERY, I.T_POINT, [I.T_REGION]),
		"point_in_region": _b(17, CAT_QUERY, I.T_BOOL, [I.T_POINT, I.T_REGION]),
		"unit_in_region": _b(18, CAT_QUERY, I.T_BOOL, [I.T_UNIT, I.T_REGION]),

		# --- entity-state queries (ids 20-39) ---
		"unit_type": _b(20, CAT_QUERY, I.T_UNITTYPE, [I.T_UNIT]),
		"owner": _b(21, CAT_QUERY, I.T_PLAYER, [I.T_UNIT]),
		"is_alive": _b(22, CAT_QUERY, I.T_BOOL, [I.T_UNIT]),
		"unit_hp": _b(23, CAT_QUERY, I.T_INT, [I.T_UNIT]),
		"unit_max_hp": _b(24, CAT_QUERY, I.T_INT, [I.T_UNIT]),
		"unit_position": _b(25, CAT_QUERY, I.T_POINT, [I.T_UNIT]),
		"is_structure": _b(26, CAT_QUERY, I.T_BOOL, [I.T_UNIT]),
		"is_unit": _b(27, CAT_QUERY, I.T_BOOL, [I.T_UNIT]),
		"build_state": _b(28, CAT_QUERY, I.T_BUILD_STATE, [I.T_UNIT]),
		"unit_stance": _b(29, CAT_QUERY, I.T_STANCE, [I.T_UNIT]),

		# --- event-context queries (ids 40-59) ---
		"triggering_unit": _b(40, CAT_CONTEXT, I.T_UNIT, []),
		"triggering_player": _b(41, CAT_CONTEXT, I.T_PLAYER, []),
		"triggering_region": _b(42, CAT_CONTEXT, I.T_REGION, []),
		"entering_unit": _b(43, CAT_CONTEXT, I.T_UNIT, []),
		"leaving_unit": _b(44, CAT_CONTEXT, I.T_UNIT, []),
		"dying_unit": _b(45, CAT_CONTEXT, I.T_UNIT, []),
		"killing_unit": _b(46, CAT_CONTEXT, I.T_UNIT, []),
		"completed_structure": _b(47, CAT_CONTEXT, I.T_UNIT, []),
		"created_unit": _b(48, CAT_CONTEXT, I.T_UNIT, []),
		"expired_timer": _b(49, CAT_CONTEXT, I.T_TIMER, []),

		# --- groups (ids 60-79) ---
		"units_in_region": _b(60, CAT_QUERY, I.T_GROUP, [I.T_REGION, I.T_FILTER]),
		"units_of_player": _b(61, CAT_QUERY, I.T_GROUP, [I.T_PLAYER, I.T_FILTER]),
		"units_in_range": _b(62, CAT_QUERY, I.T_GROUP, [I.T_POINT, I.T_FIXED, I.T_FILTER]),
		"group_size": _b(63, CAT_QUERY, I.T_INT, [I.T_GROUP]),
		"group_contains": _b(64, CAT_QUERY, I.T_BOOL, [I.T_GROUP, I.T_UNIT]),
		"random_unit_in": _b(65, CAT_QUERY, I.T_UNIT, [I.T_GROUP]),
		"nearest_unit": _b(66, CAT_QUERY, I.T_UNIT, [I.T_POINT, I.T_FILTER]),
		"units_of_type": _b(70, CAT_QUERY, I.T_GROUP, [I.T_UNITTYPE, I.T_FILTER]),
		"first_unit_in": _b(71, CAT_QUERY, I.T_UNIT, [I.T_GROUP]),
		"group_add": _b(67, CAT_ACTION, I.T_VOID, [I.T_GROUP, I.T_UNIT]),
		"group_remove": _b(68, CAT_ACTION, I.T_VOID, [I.T_GROUP, I.T_UNIT]),
		"group_clear": _b(69, CAT_ACTION, I.T_VOID, [I.T_GROUP]),

		# --- players & economy (ids 80-99) ---
		"player_resource": _b(80, CAT_QUERY, I.T_INT, [I.T_PLAYER, I.T_RESOURCE]),
		"player_unit_count": _b(81, CAT_QUERY, I.T_INT, [I.T_PLAYER, I.T_FILTER]),
		"is_enemy": _b(82, CAT_QUERY, I.T_BOOL, [I.T_PLAYER, I.T_PLAYER]),
		"is_ally": _b(83, CAT_QUERY, I.T_BOOL, [I.T_PLAYER, I.T_PLAYER]),
		"player_relation": _b(84, CAT_QUERY, I.T_RELATION, [I.T_PLAYER, I.T_PLAYER]),
		"is_visible_to": _b(90, CAT_QUERY, I.T_BOOL, [I.T_PLAYER, I.T_UNIT]),

		# --- filter constructors (ids 100-109) ---
		"ENEMY_OF": _b(100, CAT_PURE, I.T_FILTER, [I.T_PLAYER]),
		"ALLY_OF": _b(101, CAT_PURE, I.T_FILTER, [I.T_PLAYER]),
		"OWNED_BY": _b(102, CAT_PURE, I.T_FILTER, [I.T_PLAYER]),
		"OF_TYPE": _b(103, CAT_PURE, I.T_FILTER, [I.T_UNITTYPE]),

		# --- unit actions (ids 120-149) ---
		"create_unit": _b(120, CAT_ACTION, I.T_UNIT, [I.T_UNITTYPE, I.T_PLAYER, I.T_POINT]),
		"create_units": _b(121, CAT_ACTION, I.T_GROUP, [I.T_INT, I.T_UNITTYPE, I.T_PLAYER, I.T_POINT]),
		"remove_unit": _b(122, CAT_ACTION, I.T_VOID, [I.T_UNIT]),
		"kill_unit": _b(123, CAT_ACTION, I.T_VOID, [I.T_UNIT]),
		"damage_unit": _b(124, CAT_ACTION, I.T_VOID, [I.T_UNIT, I.T_INT]),
		"heal_unit": _b(125, CAT_ACTION, I.T_VOID, [I.T_UNIT, I.T_INT]),
		"set_unit_hp": _b(126, CAT_ACTION, I.T_VOID, [I.T_UNIT, I.T_INT]),
		"set_unit_position": _b(127, CAT_ACTION, I.T_VOID, [I.T_UNIT, I.T_POINT]),
		"set_owner": _b(128, CAT_ACTION, I.T_VOID, [I.T_UNIT, I.T_PLAYER]),
		"set_unit_stance": _b(129, CAT_ACTION, I.T_VOID, [I.T_UNIT, I.T_STANCE]),

		# --- economy actions (ids 150-159) ---
		"set_resource": _b(150, CAT_ACTION, I.T_VOID, [I.T_PLAYER, I.T_RESOURCE, I.T_INT]),
		"add_resource": _b(151, CAT_ACTION, I.T_VOID, [I.T_PLAYER, I.T_RESOURCE, I.T_INT]),

		# --- order bridge (ids 160-179) ---
		"order_move": _b(160, CAT_ACTION, I.T_VOID, [I.T_UNIT, I.T_POINT]),
		"order_attack": _b(161, CAT_ACTION, I.T_VOID, [I.T_UNIT, I.T_UNIT]),
		"order_attack_move": _b(162, CAT_ACTION, I.T_VOID, [I.T_UNIT, I.T_POINT]),
		"order_patrol": _b(163, CAT_ACTION, I.T_VOID, [I.T_UNIT, I.T_POINT]),
		"order_stop": _b(164, CAT_ACTION, I.T_VOID, [I.T_UNIT]),
		"order_group_move": _b(165, CAT_ACTION, I.T_VOID, [I.T_GROUP, I.T_POINT]),
		"order_group_attack_move": _b(166, CAT_ACTION, I.T_VOID, [I.T_GROUP, I.T_POINT]),
		"order_train": _b(167, CAT_ACTION, I.T_VOID, [I.T_UNIT, I.T_UNITTYPE]),
		"set_rally": _b(168, CAT_ACTION, I.T_VOID, [I.T_UNIT, I.T_POINT]),

		# --- regions (ids 180-189) ---
		"move_region": _b(180, CAT_ACTION, I.T_VOID, [I.T_REGION, I.T_POINT]),

		# --- timers (ids 190-199) ---
		"start_timer": _b(190, CAT_ACTION, I.T_TIMER, [I.T_INT, I.T_BOOL]),
		"pause_timer": _b(191, CAT_ACTION, I.T_VOID, [I.T_TIMER]),
		"resume_timer": _b(192, CAT_ACTION, I.T_VOID, [I.T_TIMER]),
		"destroy_timer": _b(193, CAT_ACTION, I.T_VOID, [I.T_TIMER]),
		"timer_remaining": _b(194, CAT_QUERY, I.T_INT, [I.T_TIMER]),

		# --- trigger control (ids 200-209) ---
		"enable_trigger": _b(200, CAT_ACTION, I.T_VOID, [I.T_TRIGGER]),
		"disable_trigger": _b(201, CAT_ACTION, I.T_VOID, [I.T_TRIGGER]),
		"is_trigger_enabled": _b(202, CAT_QUERY, I.T_BOOL, [I.T_TRIGGER]),

		# --- match control (ids 210-219) ---
		"declare_victory": _b(210, CAT_ACTION, I.T_VOID, [I.T_PLAYER]),
		"declare_defeat": _b(211, CAT_ACTION, I.T_VOID, [I.T_PLAYER]),
		"end_match": _b(212, CAT_ACTION, I.T_VOID, [I.T_PLAYER]),
		"set_player_eliminated": _b(213, CAT_ACTION, I.T_VOID, [I.T_PLAYER, I.T_BOOL]),

		# --- presentation (ids 230-249) ---
		"display_message": _b(230, CAT_PRES, I.T_VOID, [I.T_PLAYER, I.T_STRING]),
		"ping_minimap": _b(231, CAT_PRES, I.T_VOID, [I.T_PLAYER, I.T_POINT]),
	}
