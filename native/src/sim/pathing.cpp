#include "sim/pathing.h"

namespace mrts {

// Fixed neighbor order: orthogonals first, then diagonals (matches pathing.gd DIRS).
static const int DIRX[8] = {1, -1, 0, 0, 1, 1, -1, -1};
static const int DIRY[8] = {0, 0, 1, -1, 1, -1, 1, -1};

static inline int64_t absll(int64_t a) { return a < 0 ? -a : a; }

bool Pathing::diagonal_open(const SimGrid &grid, int64_t ux, int64_t uy, int64_t dx, int64_t dy) {
	if (dx == 0 || dy == 0) {
		return true;
	}
	return !grid.is_blocked(ux + dx, uy) && !grid.is_blocked(ux, uy + dy);
}

int64_t Pathing::isqrt(int64_t v) {
	if (v <= 0) {
		return 0;
	}
	int bits = 0;
	int64_t t = v;
	while (t > 0) {
		t >>= 1;
		bits += 1;
	}
	int64_t x = 1LL << ((bits + 1) >> 1);
	while (true) {
		int64_t nx = (x + v / x) >> 1;
		if (nx >= x) {
			return x;
		}
		x = nx;
	}
}

int64_t Pathing::euclid(int64_t ax, int64_t ay, int64_t bx, int64_t by) {
	int64_t dx = ax - bx;
	int64_t dy = ay - by;
	return isqrt(COST_STRAIGHT * COST_STRAIGHT * (dx * dx + dy * dy));
}

void Pathing::heap_push(std::vector<int64_t> &heap, int64_t value) {
	heap.push_back(value);
	int64_t i = (int64_t)heap.size() - 1;
	while (i > 0) {
		int64_t p = (i - 1) >> 1;
		if (heap[p] <= heap[i]) {
			break;
		}
		int64_t t = heap[p];
		heap[p] = heap[i];
		heap[i] = t;
		i = p;
	}
}

void Pathing::heap_push_keyed(std::vector<int64_t> &heap, int64_t priority, int64_t cell_index) {
	heap_push(heap, (priority << INDEX_BITS) | cell_index);
}

int64_t Pathing::heap_pop(std::vector<int64_t> &heap) {
	int64_t top = heap[0];
	int64_t last = heap[heap.size() - 1];
	heap.pop_back();
	if (!heap.empty()) {
		heap[0] = last;
		int64_t i = 0;
		int64_t n = (int64_t)heap.size();
		while (true) {
			int64_t l = 2 * i + 1;
			int64_t r = l + 1;
			int64_t s = i;
			if (l < n && heap[l] < heap[s]) {
				s = l;
			}
			if (r < n && heap[r] < heap[s]) {
				s = r;
			}
			if (s == i) {
				break;
			}
			int64_t t = heap[s];
			heap[s] = heap[i];
			heap[i] = t;
			i = s;
		}
	}
	return top;
}

bool Pathing::los(const SimGrid &grid, int64_t c0, int64_t c1) {
	int64_t w = grid.width;
	int64_t x0 = c0 % w;
	int64_t y0 = c0 / w;
	int64_t x1 = c1 % w;
	int64_t y1 = c1 / w;
	int64_t dx = absll(x1 - x0);
	int64_t dy = absll(y1 - y0);
	int64_t x = x0;
	int64_t y = y0;
	int64_t x_inc = x1 > x0 ? 1 : -1;
	int64_t y_inc = y1 > y0 ? 1 : -1;
	int64_t error = dx - dy;
	dx *= 2;
	dy *= 2;
	while (true) {
		if (grid.is_blocked(x, y)) {
			return false;
		}
		if (x == x1 && y == y1) {
			return true;
		}
		if (error > 0) {
			x += x_inc;
			error -= dy;
		} else if (error < 0) {
			y += y_inc;
			error += dx;
		} else {
			if (grid.is_blocked(x + x_inc, y) || grid.is_blocked(x, y + y_inc)) {
				return false;
			}
			x += x_inc;
			y += y_inc;
			error -= dy;
			error += dx;
		}
	}
	return true;
}

std::vector<int32_t> Pathing::theta_star(const SimGrid &grid, int64_t from_index, int64_t to_index) {
	std::vector<int32_t> path;
	if (from_index == to_index) {
		return path;
	}
	int64_t w = grid.width;
	int64_t n = w * grid.height;
	std::vector<int64_t> g((size_t)n, UNREACHABLE);
	std::vector<int64_t> parent((size_t)n, -1);
	std::vector<uint8_t> closed((size_t)n, 0);

	int64_t tx = to_index % w;
	int64_t ty = to_index / w;
	std::vector<int64_t> heap;
	g[from_index] = 0;
	parent[from_index] = from_index;
	heap_push_keyed(heap, euclid(from_index % w, from_index / w, tx, ty), from_index);

	while (!heap.empty()) {
		int64_t entry = heap_pop(heap);
		int64_t u = entry & INDEX_MASK;
		if (closed[u] == 1) {
			continue;
		}
		int64_t ux = u % w;
		int64_t uy = u / w;
		int64_t pu = parent[u];
		if (pu != u && !los(grid, pu, u)) {
			int64_t best_g = UNREACHABLE;
			int64_t best_p = -1;
			for (int k = 0; k < 8; k++) {
				int64_t vx = ux + DIRX[k];
				int64_t vy = uy + DIRY[k];
				if (!grid.in_bounds(vx, vy)) {
					continue;
				}
				if (!diagonal_open(grid, ux, uy, DIRX[k], DIRY[k])) {
					continue;
				}
				int64_t v = vy * w + vx;
				if (closed[v] != 1) {
					continue;
				}
				int64_t cg = g[v] + euclid(vx, vy, ux, uy);
				if (best_p == -1 || cg < best_g || (cg == best_g && v < best_p)) {
					best_g = cg;
					best_p = v;
				}
			}
			if (best_p == -1) {
				continue;
			}
			parent[u] = best_p;
			g[u] = best_g;
			pu = best_p;
		}
		closed[u] = 1;
		if (u == to_index) {
			break;
		}
		int64_t pux = pu % w;
		int64_t puy = pu / w;
		for (int k = 0; k < 8; k++) {
			int64_t vx = ux + DIRX[k];
			int64_t vy = uy + DIRY[k];
			if (grid.is_blocked(vx, vy)) {
				continue;
			}
			if (!diagonal_open(grid, ux, uy, DIRX[k], DIRY[k])) {
				continue;
			}
			int64_t v = vy * w + vx;
			if (closed[v] == 1) {
				continue;
			}
			int64_t ng = g[pu] + euclid(pux, puy, vx, vy);
			if (ng < g[v]) {
				g[v] = ng;
				parent[v] = pu;
				heap_push_keyed(heap, ng + euclid(vx, vy, tx, ty), v);
			}
		}
	}

	if (parent[to_index] == -1) {
		return path;
	}
	int64_t c = to_index;
	while (c != from_index) {
		path.push_back((int32_t)c);
		c = parent[c];
	}
	// reverse
	for (size_t i = 0, j = path.size(); i < j / 2; i++) {
		int32_t t = path[i];
		path[i] = path[j - 1 - i];
		path[j - 1 - i] = t;
	}
	return path;
}

} // namespace mrts
