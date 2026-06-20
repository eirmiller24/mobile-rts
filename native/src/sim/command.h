#pragma once
// A player intent fed into the sim. Bit-exact port of src/sim/sim_command.gd.
// Commands are the only mutating input after construction (lockstep wire form).
//
// `params` stays a godot::Dictionary on the native side — it is plain data
// (fixed coords, catalog ids) read once when the command executes, never
// per-tick boundary traffic. hash_into folds player_id/kind/seq/targets only
// (params are not hashed), matching the GDScript SimCommand.

#include <cstdint>
#include <vector>

#include <godot_cpp/variant/dictionary.hpp>

#include "sim/sim_hash.h"

namespace mrts {

struct Command {
	// Mirrors SimCommand.Kind ordinals exactly (sim_command.gd).
	enum Kind {
		MOVE = 0,
		ATTACK_MOVE = 1,
		PATROL = 2,
		STOP = 3,
		BUILD = 4,
		ABILITY = 5,
		SET_TACTIC = 6,
		ALLOCATE_ECONOMY = 7,
		DEBUG_SPAWN = 8,
		TRAIN = 9,
		CANCEL = 10,
		SET_RALLY = 11,
		MINE = 12,
		SET_ECONOMY = 13,
		BUILD_WALL = 14,
		REPAIR = 15,
	};

	int64_t player_id = 0;
	int64_t kind = STOP;
	std::vector<int32_t> targets; // ascending
	godot::Dictionary params;
	int64_t seq = 0;

	int64_t hash_into(int64_t h) const {
		h = SimHash::mix(h, player_id);
		h = SimHash::mix(h, kind);
		h = SimHash::mix(h, seq);
		for (int32_t t : targets) {
			h = SimHash::mix(h, t);
		}
		return h;
	}
};

} // namespace mrts
