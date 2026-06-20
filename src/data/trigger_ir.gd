class_name TriggerIR
extends RefCounted
## The trigger IR contract (docs/trigger_ir.md). These enums/strides are mirrored
## byte-for-byte in native/src/sim/trigger_ir.h; the compiler emits against them
## and the C++ VM reads against them, so any change here changes there too.
##
## Pure constants — never instantiated. The compiled program is a TriggerProgram.

# --- TriggerType: the typed value kinds (design_m5.md §3.6) ---
enum {
	T_VOID = 0,
	T_INT = 1,
	T_FIXED = 2,
	T_BOOL = 3,
	T_STRING = 4,
	T_UNIT = 5,
	T_PLAYER = 6,
	T_POINT = 7,
	T_REGION = 8,
	T_GROUP = 9,
	T_TRIGGER = 10,
	T_TIMER = 11,
	T_UNITTYPE = 12,
	T_ABILITYTYPE = 13,
	T_STANCE = 14,
	T_RESOURCE = 15,
	T_RELATION = 16,
	T_BUILD_STATE = 17,
	T_COMPARE_DIR = 18,
	T_FILTER = 19,
}

const TYPE_NAMES := {
	T_VOID: "void", T_INT: "int", T_FIXED: "fixed", T_BOOL: "bool",
	T_STRING: "string", T_UNIT: "unit", T_PLAYER: "player", T_POINT: "point",
	T_REGION: "region", T_GROUP: "group", T_TRIGGER: "trigger", T_TIMER: "timer",
	T_UNITTYPE: "unittype", T_ABILITYTYPE: "abilitytype", T_STANCE: "stance",
	T_RESOURCE: "resource", T_RELATION: "relation", T_BUILD_STATE: "build_state",
	T_COMPARE_DIR: "compare_dir", T_FILTER: "filter",
}

# Map of the type keywords usable in source (param/return/var annotations).
const TYPE_KEYWORDS := {
	"int": T_INT, "fixed": T_FIXED, "bool": T_BOOL, "string": T_STRING,
	"unit": T_UNIT, "player": T_PLAYER, "point": T_POINT, "region": T_REGION,
	"group": T_GROUP, "trigger": T_TRIGGER, "timer": T_TIMER,
	"unittype": T_UNITTYPE, "abilitytype": T_ABILITYTYPE, "stance": T_STANCE,
	"resource": T_RESOURCE, "relation": T_RELATION, "build_state": T_BUILD_STATE,
	"compare_dir": T_COMPARE_DIR, "filter": T_FILTER,
}

# --- NodeOp: the AST node tags ---
enum {
	# expressions
	OP_LIT_INT = 0,
	OP_LIT_FIXED = 1,
	OP_LIT_BOOL = 2,
	OP_LIT_NULL = 3,
	OP_LIT_STR = 4,
	OP_CONST = 5,
	OP_GLOBAL_GET = 6,
	OP_LOCAL_GET = 7,
	OP_UNOP = 8,
	OP_BINOP = 9,
	OP_CALL = 10,
	OP_BUILTIN = 11,
	# statements
	OP_BLOCK = 12,
	OP_LOCAL_DECL = 13,
	OP_ASSIGN_LOCAL = 14,
	OP_ASSIGN_GLOBAL = 15,
	OP_IF = 16,
	OP_WHILE = 17,
	OP_FOR_NUM = 18,
	OP_FOR_EACH = 19,
	OP_BREAK = 20,
	OP_RETURN = 21,
	OP_EXPR_STMT = 22,
	OP_WAIT = 23,
}

const NODE_STRIDE := 6

# --- UnOp / BinOp ---
enum { UN_NEG = 0, UN_NOT = 1 }
enum {
	BIN_ADD = 0, BIN_SUB = 1, BIN_MUL = 2, BIN_DIV = 3, BIN_MOD = 4,
	BIN_EQ = 5, BIN_NE = 6, BIN_LT = 7, BIN_LE = 8, BIN_GT = 9, BIN_GE = 10,
	BIN_AND = 11, BIN_OR = 12,
}

# --- EventKind ---
enum {
	EV_MATCH_START = 0,
	EV_MAP_INIT = 1,
	EV_EVERY = 2,
	EV_TIMER_EXPIRES = 3,
	EV_UNIT_ENTERS_REGION = 4,
	EV_UNIT_LEAVES_REGION = 5,
	EV_UNIT_DIES = 6,
	EV_STRUCTURE_COMPLETES = 7,
	EV_UNIT_CREATED = 8,
}

const EVENT_KEYWORDS := {
	"match_start": EV_MATCH_START,
	"map_init": EV_MAP_INIT,
	"every": EV_EVERY,
	"timer_expires": EV_TIMER_EXPIRES,
	"unit_enters_region": EV_UNIT_ENTERS_REGION,
	"unit_leaves_region": EV_UNIT_LEAVES_REGION,
	"unit_dies": EV_UNIT_DIES,
	"structure_completes": EV_STRUCTURE_COMPLETES,
	"unit_created": EV_UNIT_CREATED,
}

# Strides for the program's flat tables.
const GLOBAL_STRIDE := 2  # [type, init_node]
const FUNC_STRIDE := 4    # [param_count, local_count, ret_type, body_node]
const EVENT_STRIDE := 6   # [kind, p0, p1, filter, body_node, local_count]


static func type_name(t: int) -> String:
	return TYPE_NAMES.get(t, "?%d" % t)
