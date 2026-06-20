#pragma once
// Deterministic grid pathfinding. Bit-exact port of src/sim/pathing.gd.
//
// Only the parts the default config exercises are ported: Lazy Theta* (any-
// angle path search) and its LOS supercover. The flow-field machinery
// (FlowBuild) is dead under USE_FLOW_FIELDS=false (every order routes per-unit
// with theta*), so it is intentionally not ported — re-enabling flow fields in
// C++ means porting FlowBuild here (design_m5.md note; pathing.gd remains the
// reference).

#include <cstdint>
#include <vector>

#include "sim/sim_grid.h"

namespace mrts {

struct Pathing {
	static constexpr int COST_STRAIGHT = 5;
	static constexpr int COST_DIAGONAL = 7;
	static constexpr int64_t UNREACHABLE = 0x7FFFFFFF;
	static constexpr int INDEX_BITS = 24;
	static constexpr int64_t INDEX_MASK = (1LL << INDEX_BITS) - 1;

	// Any-angle path from from_index to to_index, as cell indices excluding the
	// start and including the goal; empty if unreachable or already there.
	static std::vector<int32_t> theta_star(const SimGrid &grid, int64_t from_index, int64_t to_index);

	// Straight line between two cell centers crosses only unblocked cells.
	static bool los(const SimGrid &grid, int64_t c0, int64_t c1);

private:
	static bool diagonal_open(const SimGrid &grid, int64_t ux, int64_t uy, int64_t dx, int64_t dy);
	static int64_t euclid(int64_t ax, int64_t ay, int64_t bx, int64_t by);
	static int64_t isqrt(int64_t v);

	static void heap_push_keyed(std::vector<int64_t> &heap, int64_t priority, int64_t cell_index);
	static void heap_push(std::vector<int64_t> &heap, int64_t value);
	static int64_t heap_pop(std::vector<int64_t> &heap);
};

} // namespace mrts
