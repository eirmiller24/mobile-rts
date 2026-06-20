#pragma once
// Per-player sim state. Bit-exact port of src/sim/sim_player.gd. Bandwidth is
// derived on query, never stored.

#include <cstdint>
#include <vector>
#include "sim/sim_hash.h"

namespace mrts {

struct Player {
	int64_t id = 0;
	int64_t faction = 0; // interned faction name (SimHash::fnv_string)
	int64_t alloy = 0;   // fixed
	int64_t flux = 0;    // fixed

	bool auto_repair = false;

	std::vector<int32_t> discovered_resources;

	int64_t eliminated_tick = -1;
	bool had_main = false;

	std::vector<int32_t> wall_cells;
	std::vector<int32_t> wall_claims;
	int64_t wall_type = -1;

	int64_t hash_into(int64_t h) const {
		const int64_t flat[] = {
			id, faction, alloy, flux,
			(int64_t)auto_repair, eliminated_tick, (int64_t)had_main,
			wall_type
		};
		for (int64_t v : flat) {
			h = SimHash::mix(h, v);
		}
		for (int32_t v : discovered_resources) {
			h = SimHash::mix(h, v);
		}
		for (int32_t v : wall_cells) {
			h = SimHash::mix(h, v);
		}
		for (int32_t v : wall_claims) {
			h = SimHash::mix(h, v);
		}
		return h;
	}
};

} // namespace mrts
