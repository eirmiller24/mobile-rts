#pragma once
// The trigger IR enums, mirrored byte-for-byte from src/data/trigger_ir.gd and
// src/data/trigger_registry.gd (docs/trigger_ir.md). The GDScript compiler emits
// against these tags/ids; the C++ VM reads against them. Any change on one side
// is a change on the other — the integer values are the wire contract.

#include <cstdint>

namespace mrts {
namespace tir {

// TriggerType — the typed value kinds (design_m5.md §3.6).
enum Type {
	T_VOID = 0, T_INT = 1, T_FIXED = 2, T_BOOL = 3, T_STRING = 4,
	T_UNIT = 5, T_PLAYER = 6, T_POINT = 7, T_REGION = 8, T_GROUP = 9,
	T_TRIGGER = 10, T_TIMER = 11, T_UNITTYPE = 12, T_ABILITYTYPE = 13,
	T_STANCE = 14, T_RESOURCE = 15, T_RELATION = 16, T_BUILD_STATE = 17,
	T_COMPARE_DIR = 18, T_FILTER = 19,
};

// NodeOp — the AST node tags.
enum Op {
	OP_LIT_INT = 0, OP_LIT_FIXED = 1, OP_LIT_BOOL = 2, OP_LIT_NULL = 3,
	OP_LIT_STR = 4, OP_CONST = 5, OP_GLOBAL_GET = 6, OP_LOCAL_GET = 7,
	OP_UNOP = 8, OP_BINOP = 9, OP_CALL = 10, OP_BUILTIN = 11,
	OP_BLOCK = 12, OP_LOCAL_DECL = 13, OP_ASSIGN_LOCAL = 14, OP_ASSIGN_GLOBAL = 15,
	OP_IF = 16, OP_WHILE = 17, OP_FOR_NUM = 18, OP_FOR_EACH = 19,
	OP_BREAK = 20, OP_RETURN = 21, OP_EXPR_STMT = 22, OP_WAIT = 23,
};

enum UnOp { UN_NEG = 0, UN_NOT = 1 };

enum BinOp {
	BIN_ADD = 0, BIN_SUB = 1, BIN_MUL = 2, BIN_DIV = 3, BIN_MOD = 4,
	BIN_EQ = 5, BIN_NE = 6, BIN_LT = 7, BIN_LE = 8, BIN_GT = 9, BIN_GE = 10,
	BIN_AND = 11, BIN_OR = 12,
};

enum EventKind {
	EV_MATCH_START = 0, EV_MAP_INIT = 1, EV_EVERY = 2, EV_TIMER_EXPIRES = 3,
	EV_UNIT_ENTERS_REGION = 4, EV_UNIT_LEAVES_REGION = 5, EV_UNIT_DIES = 6,
	EV_STRUCTURE_COMPLETES = 7, EV_UNIT_CREATED = 8,
};

// FilterKind — a FILTER value carries {kind, arg} (registry FK_*).
enum FilterKind {
	FK_ANY = 0, FK_ALIVE = 1, FK_IS_STRUCTURE = 2, FK_IS_UNIT = 3,
	FK_ENEMY_OF = 4, FK_ALLY_OF = 5, FK_OWNED_BY = 6, FK_OF_TYPE = 7,
};

// BuiltinId — the standard-library ids (registry `id` field). Add a row in
// trigger_registry.gd AND here AND a handler in trigger_vm.cpp to grow it.
enum BuiltinId {
	B_MIN = 0, B_MAX = 1, B_ABS = 2, B_CLAMP = 3, B_RANDOM_INT = 4,
	B_TO_FIXED = 5, B_FLOOR = 6, B_ROUND = 7, B_RANDOM_FIXED = 8,
	B_POINT = 10, B_POINT_X = 11, B_POINT_Y = 12, B_OFFSET = 13, B_DISTANCE = 14,
	B_REGION_CENTER = 15, B_REGION_RANDOM_POINT = 16, B_POINT_IN_REGION = 17,
	B_UNIT_IN_REGION = 18,
	B_UNIT_TYPE = 20, B_OWNER = 21, B_IS_ALIVE = 22, B_UNIT_HP = 23,
	B_UNIT_MAX_HP = 24, B_UNIT_POSITION = 25, B_IS_STRUCTURE = 26, B_IS_UNIT = 27,
	B_BUILD_STATE = 28, B_UNIT_STANCE = 29,
	B_TRIGGERING_UNIT = 40, B_TRIGGERING_PLAYER = 41, B_TRIGGERING_REGION = 42,
	B_ENTERING_UNIT = 43, B_LEAVING_UNIT = 44, B_DYING_UNIT = 45,
	B_KILLING_UNIT = 46, B_COMPLETED_STRUCTURE = 47, B_CREATED_UNIT = 48,
	B_EXPIRED_TIMER = 49,
	B_UNITS_IN_REGION = 60, B_UNITS_OF_PLAYER = 61, B_UNITS_IN_RANGE = 62,
	B_GROUP_SIZE = 63, B_GROUP_CONTAINS = 64, B_RANDOM_UNIT_IN = 65,
	B_NEAREST_UNIT = 66, B_GROUP_ADD = 67, B_GROUP_REMOVE = 68, B_GROUP_CLEAR = 69,
	B_UNITS_OF_TYPE = 70, B_FIRST_UNIT_IN = 71,
	B_PLAYER_RESOURCE = 80, B_PLAYER_UNIT_COUNT = 81, B_IS_ENEMY = 82, B_IS_ALLY = 83,
	B_PLAYER_RELATION = 84, B_IS_VISIBLE_TO = 90,
	B_ENEMY_OF = 100, B_ALLY_OF = 101, B_OWNED_BY = 102, B_OF_TYPE = 103,
	B_CREATE_UNIT = 120, B_CREATE_UNITS = 121, B_REMOVE_UNIT = 122, B_KILL_UNIT = 123,
	B_DAMAGE_UNIT = 124, B_HEAL_UNIT = 125, B_SET_UNIT_HP = 126,
	B_SET_UNIT_POSITION = 127, B_SET_OWNER = 128, B_SET_UNIT_STANCE = 129,
	B_SET_RESOURCE = 150, B_ADD_RESOURCE = 151,
	B_ORDER_MOVE = 160, B_ORDER_ATTACK = 161, B_ORDER_ATTACK_MOVE = 162,
	B_ORDER_PATROL = 163, B_ORDER_STOP = 164, B_ORDER_GROUP_MOVE = 165,
	B_ORDER_GROUP_ATTACK_MOVE = 166, B_ORDER_TRAIN = 167, B_SET_RALLY = 168,
	B_MOVE_REGION = 180,
	B_START_TIMER = 190, B_PAUSE_TIMER = 191, B_RESUME_TIMER = 192,
	B_DESTROY_TIMER = 193, B_TIMER_REMAINING = 194,
	B_ENABLE_TRIGGER = 200, B_DISABLE_TRIGGER = 201, B_IS_TRIGGER_ENABLED = 202,
	B_DECLARE_VICTORY = 210, B_DECLARE_DEFEAT = 211, B_END_MATCH = 212,
	B_SET_PLAYER_ELIMINATED = 213,
	B_DISPLAY_MESSAGE = 230, B_PING_MINIMAP = 231,
};

constexpr int NODE_STRIDE = 6;
constexpr int GLOBAL_STRIDE = 2;
constexpr int FUNC_STRIDE = 4;
constexpr int EVENT_STRIDE = 6;

// Resource enum constants (match schema RK_ALLOY/RK_FLUX and registry).
constexpr int RES_ALLOY = 0;
constexpr int RES_FLUX = 1;

} // namespace tir
} // namespace mrts
