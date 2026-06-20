#pragma once
// The sim's spatial grid. Bit-exact port of src/sim/sim_grid.gd.
//
// Two resolutions share one cell store: the build grid (1 tile = Fixed::ONE
// world units) and the pathing grid (PATH_SUBDIV cells per tile side) that
// movement, flow fields, and collision run on. Blocked state is a per-cell
// count so overlapping blockers compose.

#include <cstdint>
#include <vector>
#include "sim/fixed.h"

namespace mrts {

struct SimGrid {
	static constexpr int PATH_SUBDIV = 2;
	// Fixed-point world size of one pathing cell.
	static constexpr int64_t CELL = Fixed::ONE / PATH_SUBDIV;

	int64_t tiles_w = 0;
	int64_t tiles_h = 0;
	// Dimensions in pathing cells.
	int64_t width = 0;
	int64_t height = 0;
	// Bumped on every blocking change; flow fields cache against it.
	int64_t version = 0;

	std::vector<uint8_t> blocked;
	// Cached content hash of `blocked`, against `version` (derived data).
	mutable int64_t blocked_hash = 0;
	mutable int64_t blocked_hash_version = -1;

	SimGrid() = default;
	SimGrid(int64_t p_tiles_w, int64_t p_tiles_h);

	inline int64_t world_w() const { return tiles_w * Fixed::ONE; }
	inline int64_t world_h() const { return tiles_h * Fixed::ONE; }

	inline int64_t index(int64_t cx, int64_t cy) const { return cy * width + cx; }

	inline bool in_bounds(int64_t cx, int64_t cy) const {
		return cx >= 0 && cy >= 0 && cx < width && cy < height;
	}

	// Out-of-bounds counts as blocked.
	inline bool is_blocked(int64_t cx, int64_t cy) const {
		if (!in_bounds(cx, cy)) {
			return true;
		}
		return blocked[cy * width + cx] > 0;
	}

	inline bool is_blocked_index(int64_t i) const { return blocked[i] > 0; }

	// Pathing cell containing fixed-point world coordinate `f`.
	inline int64_t cell_of(int64_t f) const {
		return (f * PATH_SUBDIV) >> Fixed::SHIFT;
	}

	// Fixed-point world coordinate of a pathing cell's center.
	inline int64_t cell_center(int64_t c) const { return c * CELL + CELL / 2; }

	void block_rect(int64_t cx, int64_t cy, int64_t w, int64_t h);
	void unblock_rect(int64_t cx, int64_t cy, int64_t w, int64_t h);
	bool rect_free(int64_t cx, int64_t cy, int64_t w, int64_t h) const;
	int64_t nearest_free_cell(int64_t cx, int64_t cy, int64_t max_radius = 16) const;

	int64_t hash_into(int64_t h) const;

private:
	void adjust_rect(int64_t cx, int64_t cy, int64_t w, int64_t h, int delta);
};

} // namespace mrts
