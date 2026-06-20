#include "sim/sim_grid.h"

#include <cstdlib>
#include "sim/sim_hash.h"

namespace mrts {

SimGrid::SimGrid(int64_t p_tiles_w, int64_t p_tiles_h) {
	tiles_w = p_tiles_w;
	tiles_h = p_tiles_h;
	width = p_tiles_w * PATH_SUBDIV;
	height = p_tiles_h * PATH_SUBDIV;
	blocked.assign((size_t)(width * height), 0);
}

void SimGrid::adjust_rect(int64_t cx, int64_t cy, int64_t w, int64_t h, int delta) {
	for (int64_t y = cy; y < cy + h; y++) {
		for (int64_t x = cx; x < cx + w; x++) {
			// assert(in_bounds(x, y), "blocking outside the grid")
			int64_t i = y * width + x;
			int v = blocked[i] + delta;
			// assert(v >= 0 and v <= 255)
			blocked[i] = (uint8_t)v;
		}
	}
	version += 1;
}

void SimGrid::block_rect(int64_t cx, int64_t cy, int64_t w, int64_t h) {
	adjust_rect(cx, cy, w, h, 1);
}

void SimGrid::unblock_rect(int64_t cx, int64_t cy, int64_t w, int64_t h) {
	adjust_rect(cx, cy, w, h, -1);
}

bool SimGrid::rect_free(int64_t cx, int64_t cy, int64_t w, int64_t h) const {
	for (int64_t y = cy; y < cy + h; y++) {
		for (int64_t x = cx; x < cx + w; x++) {
			if (is_blocked(x, y)) {
				return false;
			}
		}
	}
	return true;
}

int64_t SimGrid::nearest_free_cell(int64_t cx, int64_t cy, int64_t max_radius) const {
	if (!is_blocked(cx, cy)) {
		return index(cx, cy);
	}
	for (int64_t r = 1; r <= max_radius; r++) {
		for (int64_t dy = -r; dy <= r; dy++) {
			for (int64_t dx = -r; dx <= r; dx++) {
				int64_t ax = dx < 0 ? -dx : dx;
				int64_t ay = dy < 0 ? -dy : dy;
				if ((ax > ay ? ax : ay) != r) {
					continue;
				}
				int64_t x = cx + dx;
				int64_t y = cy + dy;
				if (in_bounds(x, y) && !is_blocked(x, y)) {
					return index(x, y);
				}
			}
		}
	}
	return -1;
}

int64_t SimGrid::hash_into(int64_t h) const {
	if (blocked_hash_version != version) {
		blocked_hash = SimHash::fnv_bytes(blocked.data(), blocked.size());
		blocked_hash_version = version;
	}
	h = SimHash::mix(h, version);
	h = SimHash::mix(h, blocked_hash);
	return h;
}

} // namespace mrts
