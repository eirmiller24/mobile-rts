#pragma once
// A named map area (design_m5.md §3.6) — a fixed-point rectangle in world
// coords. Loaded from the map and interned; trigger events fire on it and a
// trigger action can move/resize it, so it is hashed sim state. Shared by sim.h
// and trigger_vm.h.

#include <cstdint>
#include "sim/sim_hash.h"

namespace mrts {

struct Region {
	int64_t id = 0;
	int64_t min_x = 0; // fixed-point world bounds, half-open [min, max)
	int64_t min_y = 0;
	int64_t max_x = 0;
	int64_t max_y = 0;

	inline bool contains(int64_t x, int64_t y) const {
		return x >= min_x && x < max_x && y >= min_y && y < max_y;
	}
	inline int64_t center_x() const { return (min_x + max_x) / 2; }
	inline int64_t center_y() const { return (min_y + max_y) / 2; }

	int64_t hash_into(int64_t h) const {
		h = SimHash::mix(h, id);
		h = SimHash::mix(h, min_x);
		h = SimHash::mix(h, min_y);
		h = SimHash::mix(h, max_x);
		h = SimHash::mix(h, max_y);
		return h;
	}
};

} // namespace mrts
