// Movement, collision, steering, arrival — port of the _movement_system family
// in sim.gd. All methods of mrts::Sim.
//
// NOTE: the flow-field branch of _waypoint is stubbed to "hold position"
// (identical to what GDScript returns while a field is still building). It is
// only reachable in an edge case under USE_FLOW_FIELDS=false (a small order
// whose start cell == goal cell, with the unit later shoved off-goal). The
// parity harness will flag it if it is ever actually hit; if so, the flow-field
// machinery (pathing.gd FlowBuild + _flow_entry/_flow_waypoint) must be ported.
#include "sim/sim.h"

#include <algorithm>

#include "sim/sim_util.h"

using namespace godot;

namespace mrts {

void Sim::_movement_system() {
	std::vector<int64_t> ids = _sorted_ids();

	_rebuild_buckets(ids);

	for (int64_t id : ids) {
		Entity *e = E(id);
		if (!e->is_unit() || e->hp <= 0 || e->orders.is_empty()) {
			continue;
		}
		if (e->is_underground() || e->morph_ticks_left > 0) {
			continue;
		}
		Dictionary o = e->orders[0];
		if ((int64_t)o["kind"] == Command::ATTACK_MOVE && e->stance != schema::SKIRMISH) {
			if (_engaged(*e)) {
				continue;
			}
			if (!(e->tactic_flags & schema::HOLD_POSITION)) {
				Entity *at = e->target_id != 0 ? E(e->target_id) : nullptr;
				if (at != nullptr && at->hp > 0 && _can_target(*e, *at) &&
						_in_range(*e, *at, e->acquire_range, false)) {
					int64_t adx = at->x - e->x;
					int64_t ady = at->y - e->y;
					int64_t ad = _length(adx, ady);
					if (ad > 0) {
						V2 st = _steer_around(*e, adx, ady, ad);
						int64_t sd = _length(st.x, st.y);
						if (sd > 0) {
							e->x += st.x * e->step / sd;
							e->y += st.y * e->step / sd;
						}
					}
					continue;
				}
			}
		}
		if (o.has("slot_x")) {
			int64_t gdx = (int64_t)o["x"] - e->x;
			int64_t gdy = (int64_t)o["y"] - e->y;
			if (absi(gdx) <= SLOT_SWITCH_DIST && absi(gdy) <= SLOT_SWITCH_DIST &&
					_length(gdx, gdy) <= SLOT_SWITCH_DIST) {
				o["x"] = o["slot_x"];
				o["y"] = o["slot_y"];
				o.erase("slot_x");
				o.erase("slot_y");
				o["small"] = true;
				o["cluster"] = ARRIVE_DIST + e->radius * 2;
				_start_order(*e);
				if (e->orders.is_empty()) {
					continue;
				}
				o = e->orders[0];
			}
		}
		V2 wp = _waypoint(*e, o);
		if (wp == give_up()) {
			_drop_order(*e);
			continue;
		}
		int64_t dx = wp.x - e->x;
		int64_t dy = wp.y - e->y;
		int64_t d = _length(dx, dy);
		if (d <= e->step) {
			e->x = wp.x;
			e->y = wp.y;
		} else if (d > 0) {
			V2 s = _steer_around(*e, dx, dy, d);
			int64_t sd = _length(s.x, s.y);
			if (sd > 0) {
				e->x += s.x * e->step / sd;
				e->y += s.y * e->step / sd;
			}
		}
	}

	_rebuild_buckets(ids);

	std::vector<int64_t> crowd_done;
	for (int64_t id : ids) {
		Entity *e = E(id);
		if (!e->is_unit() || e->hp <= 0 || e->is_underground()) {
			continue;
		}
		for (int64_t nid : _bucket_neighbors(*e, 1, id)) {
			Entity *n = E(nid);
			if (!n->is_unit() || n->hp <= 0) {
				continue;
			}
			int64_t dx = n->x - e->x;
			int64_t dy = n->y - e->y;
			int64_t rr = e->radius + n->radius;
			if (absi(dx) >= rr || absi(dy) >= rr) {
				continue;
			}
			int64_t d2 = Fixed::mul(dx, dx) + Fixed::mul(dy, dy);
			if (d2 >= Fixed::mul(rr, rr)) {
				continue;
			}
			int64_t d = Fixed::sqrt(d2);
			if (d == 0) {
				e->x -= (rr - d) / 2;
				n->x += (rr - d) / 2;
			} else {
				int64_t push = (rr - d) / 2;
				e->x -= dx * push / d;
				e->y -= dy * push / d;
				n->x += dx * push / d;
				n->y += dy * push / d;
			}
			if (_arrived_neighbor(*e, *n)) {
				crowd_done.push_back(e->id);
			}
			if (_arrived_neighbor(*n, *e)) {
				crowd_done.push_back(n->id);
			}
		}
	}

	for (int64_t id : ids) {
		Entity *e = E(id);
		if (!e->is_unit() || e->hp <= 0 || e->is_underground()) {
			continue;
		}
		_push_out_of_blocked(*e);
		e->x = clampi(e->x, e->radius, grid.world_w() - e->radius);
		e->y = clampi(e->y, e->radius, grid.world_h() - e->radius);
	}

	std::sort(crowd_done.begin(), crowd_done.end());
	int64_t prev_done = 0;
	for (int64_t id : crowd_done) {
		if (id == prev_done) {
			continue;
		}
		prev_done = id;
		Entity *e = E(id);
		if (!e->orders.is_empty()) {
			_complete_order(*e);
		}
	}
	for (int64_t id : ids) {
		Entity *e = E(id);
		if (!e->is_unit() || e->hp <= 0 || e->orders.is_empty()) {
			continue;
		}
		Dictionary o = e->orders[0];
		int64_t dx = (int64_t)o["x"] - e->x;
		int64_t dy = (int64_t)o["y"] - e->y;
		int64_t d2 = Fixed::mul(dx, dx) + Fixed::mul(dy, dy);
		if (d2 <= Fixed::mul(ARRIVE_DIST, ARRIVE_DIST)) {
			_complete_order(*e);
		} else if ((int64_t)o["kind"] == Command::ATTACK_MOVE && e->target_id != 0) {
			e->stall = 0;
		} else if (d2 < e->goal_d2_best) {
			e->goal_d2_best = d2;
			e->stall = 0;
		} else {
			e->stall += 1;
			if (e->stall >= STALL_GIVE_UP_TICKS) {
				_drop_order(*e);
			}
		}
	}
}

V2 Sim::_waypoint(Entity &e, Dictionary &o) {
	int64_t cur = _cell_index_of(e);
	if (cur == e.goal_key) {
		return V2{(int64_t)o["x"], (int64_t)o["y"]};
	}
	if (!e.path.empty()) {
		for (int64_t i = e.path_i; i < (int64_t)e.path.size(); i++) {
			if (e.path[i] == cur) {
				e.path_i = i + 1;
			}
		}
		while (e.path_i < (int64_t)e.path.size()) {
			int64_t pc = e.path[e.path_i];
			int64_t px = grid.cell_center(pc % grid.width);
			int64_t py = grid.cell_center(pc / grid.width);
			if (_length(px - e.x, py - e.y) <= WAYPOINT_REACH) {
				e.path_i += 1;
			} else {
				break;
			}
		}
		if (e.path_i >= (int64_t)e.path.size()) {
			return V2{(int64_t)o["x"], (int64_t)o["y"]};
		}
		int64_t c = e.path[e.path_i];
		return V2{grid.cell_center(c % grid.width), grid.cell_center(c / grid.width)};
	}
	if (grid.is_blocked_index(cur)) {
		return V2{(int64_t)o["x"], (int64_t)o["y"]};
	}
	// flow-field branch (USE_FLOW_FIELDS=false): hold position (see file header).
	return V2{e.x, e.y};
}

V2 Sim::_steer_around(const Entity &e, int64_t dx, int64_t dy, int64_t d) {
	int64_t lookahead = e.step * 4;
	Entity *best = nullptr;
	int64_t best_d2 = 0;
	for (int64_t nid : _bucket_neighbors(e, 1, 0)) {
		Entity *n = E(nid);
		if (!n->is_unit() || n->hp <= 0 || !n->orders.is_empty()) {
			continue;
		}
		int64_t tx = n->x - e.x;
		int64_t ty = n->y - e.y;
		int64_t rr = e.radius + n->radius;
		int64_t lim = rr + lookahead;
		if (absi(tx) > lim || absi(ty) > lim) {
			continue;
		}
		int64_t nd2 = Fixed::mul(tx, tx) + Fixed::mul(ty, ty);
		if (nd2 == 0 || nd2 > Fixed::mul(lim, lim)) {
			continue;
		}
		if (Fixed::mul(dx, tx) + Fixed::mul(dy, ty) <= 0) {
			continue;
		}
		if (absi(Fixed::mul(dx, ty) - Fixed::mul(dy, tx)) >= Fixed::mul(rr, d)) {
			continue;
		}
		if (best == nullptr || nd2 < best_d2 || (nd2 == best_d2 && n->id < best->id)) {
			best = n;
			best_d2 = nd2;
		}
	}
	if (best == nullptr) {
		return V2{dx, dy};
	}
	int64_t bx = best->x - e.x;
	int64_t by = best->y - e.y;
	if (Fixed::mul(dx, by) - Fixed::mul(dy, bx) > 0) {
		return V2{by, -bx};
	}
	return V2{-by, bx};
}

bool Sim::_arrived_neighbor(const Entity &e, const Entity &n) const {
	if (e.goal_key == -1 || e.orders.is_empty()) {
		return false;
	}
	Dictionary o = e.orders[0];
	int64_t group = (int64_t)o.get("group", e.goal_key);
	if (!n.orders.is_empty() || n.done_goal_key != group) {
		return false;
	}
	if (e.stall >= STALL_TICKS) {
		return true;
	}
	int64_t dx = (int64_t)o["x"] - e.x;
	int64_t dy = (int64_t)o["y"] - e.y;
	int64_t cluster = (int64_t)o.get("cluster", ARRIVE_DIST);
	if (absi(dx) > cluster || absi(dy) > cluster) {
		return false;
	}
	return Fixed::mul(dx, dx) + Fixed::mul(dy, dy) <= Fixed::mul(cluster, cluster);
}

void Sim::_complete_order(Entity &e) {
	Dictionary o = e.orders[0];
	if ((bool)o.get("patrol", false)) {
		if ((int64_t)o["x"] == (int64_t)o["bx"] && (int64_t)o["y"] == (int64_t)o["by"]) {
			o["x"] = o["ax"];
			o["y"] = o["ay"];
		} else {
			o["x"] = o["bx"];
			o["y"] = o["by"];
		}
		_start_order(e);
		return;
	}
	e.done_goal_key = (int64_t)o.get("group", e.goal_key);
	e.orders.pop_front();
	_start_order(e);
}

void Sim::_drop_order(Entity &e) {
	e.orders.pop_front();
	_start_order(e);
}

void Sim::_push_out_of_blocked(Entity &e) {
	int64_t cx = grid.cell_of(e.x);
	int64_t cy = grid.cell_of(e.y);
	for (int64_t oy = -1; oy <= 1; oy++) {
		for (int64_t ox = -1; ox <= 1; ox++) {
			int64_t bx = cx + ox;
			int64_t by = cy + oy;
			if (!grid.is_blocked(bx, by)) {
				continue;
			}
			int64_t min_x = bx * SimGrid::CELL;
			int64_t min_y = by * SimGrid::CELL;
			int64_t max_x = min_x + SimGrid::CELL;
			int64_t max_y = min_y + SimGrid::CELL;
			int64_t px = clampi(e.x, min_x, max_x);
			int64_t py = clampi(e.y, min_y, max_y);
			int64_t dx = e.x - px;
			int64_t dy = e.y - py;
			if (absi(dx) >= e.radius || absi(dy) >= e.radius) {
				continue;
			}
			if (dx == 0 && dy == 0) {
				int64_t pens[4] = {e.x - min_x, max_x - e.x, e.y - min_y, max_y - e.y};
				int64_t mn = pens[0];
				int64_t face = 0;
				for (int i = 1; i < 4; i++) {
					if (pens[i] < mn) {
						mn = pens[i];
						face = i;
					}
				}
				switch (face) {
					case 0: e.x = min_x - e.radius; break;
					case 1: e.x = max_x + e.radius; break;
					case 2: e.y = min_y - e.radius; break;
					case 3: e.y = max_y + e.radius; break;
				}
				continue;
			}
			int64_t d2 = Fixed::mul(dx, dx) + Fixed::mul(dy, dy);
			if (d2 >= Fixed::mul(e.radius, e.radius)) {
				continue;
			}
			int64_t d = Fixed::sqrt(d2);
			if (d == 0) {
				continue;
			}
			int64_t push = e.radius - d;
			e.x += dx * push / d;
			e.y += dy * push / d;
		}
	}
}

void Sim::_rebuild_buckets(const std::vector<int64_t> &ids) {
	_buckets.clear();
	for (int64_t id : ids) {
		Entity *e = E(id);
		if (e->hp <= 0) {
			continue;
		}
		if (e->is_unit()) {
			if (e->is_underground()) {
				continue;
			}
			_bucket_insert(e->x >> BUCKET_SHIFT, e->y >> BUCKET_SHIFT, id);
		} else {
			int64_t x0 = (e->foot_x * SimGrid::CELL) >> BUCKET_SHIFT;
			int64_t y0 = (e->foot_y * SimGrid::CELL) >> BUCKET_SHIFT;
			int64_t x1 = ((e->foot_x + e->foot_w) * SimGrid::CELL) >> BUCKET_SHIFT;
			int64_t y1 = ((e->foot_y + e->foot_h) * SimGrid::CELL) >> BUCKET_SHIFT;
			for (int64_t by = y0; by <= y1; by++) {
				for (int64_t bx = x0; bx <= x1; bx++) {
					_bucket_insert(bx, by, id);
				}
			}
		}
	}
}

void Sim::_bucket_insert(int64_t bx, int64_t by, int64_t id) {
	_buckets[{bx, by}].push_back((int32_t)id);
}

std::vector<int64_t> Sim::_bucket_neighbors(const Entity &e, int64_t radius_buckets, int64_t above) const {
	int64_t bx = e.x >> BUCKET_SHIFT;
	int64_t by = e.y >> BUCKET_SHIFT;
	std::vector<int64_t> result;
	for (int64_t oy = -radius_buckets; oy <= radius_buckets; oy++) {
		for (int64_t ox = -radius_buckets; ox <= radius_buckets; ox++) {
			auto it = _buckets.find({bx + ox, by + oy});
			if (it == _buckets.end()) {
				continue;
			}
			for (int32_t id : it->second) {
				if (id > above && id != e.id) {
					result.push_back(id);
				}
			}
		}
	}
	return result;
}

int64_t Sim::_length(int64_t dx, int64_t dy) const {
	return Fixed::sqrt(Fixed::mul(dx, dx) + Fixed::mul(dy, dy));
}

int64_t Sim::_isqrt(int64_t n) const {
	int64_t r = 0;
	while ((r + 1) * (r + 1) <= n) {
		r += 1;
	}
	return r;
}

} // namespace mrts
