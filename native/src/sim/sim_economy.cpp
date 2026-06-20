// Nanomachine + worker economy, worker build, drawn walls — port of the
// _economy_system / _worker_economy_system / _worker_build_system / _wall_system
// families in sim.gd.
#include "sim/sim.h"

#include <algorithm>
#include <map>
#include <vector>

#include "sim/sim_util.h"

using namespace godot;

namespace mrts {

// --- nanomachine economy ----------------------------------------------------
void Sim::_economy_system() {
	_income.clear();
	for (int64_t id : _sorted_ids()) {
		Entity *e = E(id);
		if (e->kind != Entity::STRUCTURE || !_functional(e)) {
			continue;
		}
		Dictionary s = catalog.sim_of(e->type_key);
		int64_t pool = (int64_t)s["nano_pool"];
		if (pool <= 0) {
			continue;
		}
		Player *player = players.find(e->player);
		if (player == nullptr) {
			continue;
		}
		int64_t r = _territory_radius(*e);
		int64_t alloc0 = e->nano_alloc[0], alloc1 = e->nano_alloc[1], alloc2 = e->nano_alloc[2];
		int64_t assist_used = _assist(*e, r, alloc2);
		int64_t idle_assist = alloc2 - assist_used;
		int64_t mine_alloy = alloc0;
		int64_t mine_flux = alloc1;
		if (idle_assist > 0) {
			int64_t base = alloc0 + alloc1;
			int64_t extra_alloy = base == 0 ? idle_assist / 2 : idle_assist * alloc0 / base;
			mine_alloy += extra_alloy;
			mine_flux += idle_assist - extra_alloy;
		}
		int64_t mined_alloy = _mine(*e, *player, r, schema::RK_ALLOY, (int64_t)catalog.globals["alloy_rate"], mine_alloy);
		int64_t mined_flux = _mine(*e, *player, r, schema::RK_FLUX, (int64_t)catalog.globals["flux_rate"], mine_flux);
		// income (view-only, never hashed).
		_income[e->id] = {mined_alloy, mined_flux, assist_used, idle_assist,
				pool - alloc0 - alloc1 - alloc2};
	}
}

int64_t Sim::_territory_radius(const Entity &e) const {
	PackedInt32Array abilities = _abilities_of(e);
	for (int i = 0; i < abilities.size(); i++) {
		Dictionary ab = catalog.sim_of(abilities[i]);
		if ((int64_t)ab["ability_kind"] == schema::AURA) {
			PackedStringArray flags = ab["flags"];
			if (flags.has("territory")) {
				return (int64_t)ab["radius"];
			}
		}
	}
	return 0;
}

int64_t Sim::_mine(Entity &sh, Player &player, int64_t r, int64_t res_kind, int64_t rate, int64_t nanos) {
	if (nanos <= 0 || r <= 0) {
		return 0;
	}
	int64_t demand = (rate / TICK_RATE) * nanos;
	int64_t mined = 0;
	for (int64_t id : _sorted_ids()) {
		if (demand <= 0) {
			break;
		}
		Entity *node = nullptr;
		if (res_kind == schema::RK_ALLOY) {
			Entity *n = E(id);
			if (!n->is_resource() || n->resource_kind != res_kind) {
				continue;
			}
			if (!_circle_covers(sh.x, sh.y, r, n->x, n->y)) {
				continue;
			}
			node = n;
		} else {
			Entity *siphon = E(id);
			if (siphon->kind != Entity::STRUCTURE || siphon->vent_id == 0 ||
					siphon->player != sh.player || !_functional(siphon)) {
				continue;
			}
			if (!_circle_covers(sh.x, sh.y, r, siphon->x, siphon->y)) {
				continue;
			}
			node = E(siphon->vent_id);
			if (node == nullptr) {
				continue;
			}
		}
		if (node->amount <= 0) {
			continue;
		}
		int64_t cap = (int64_t)catalog.sim_of(node->type_key)["throughput"] / TICK_RATE;
		int64_t draw = mini(demand, mini(cap, node->amount));
		node->amount -= draw;
		demand -= draw;
		mined += draw;
	}
	if (res_kind == schema::RK_ALLOY) {
		player.alloy += mined;
	} else {
		player.flux += mined;
	}
	return mined;
}

int64_t Sim::_assist(Entity &sh, int64_t r, int64_t nanos) {
	if (nanos <= 0 || r <= 0) {
		return 0;
	}
	std::vector<Entity *> growing;
	std::vector<Entity *> damaged;
	for (int64_t id : _sorted_ids()) {
		Entity *e = E(id);
		if (e->kind != Entity::STRUCTURE || e->hp <= 0 || e->player != sh.player) {
			continue;
		}
		if (!_circle_covers(sh.x, sh.y, r, e->x, e->y)) {
			continue;
		}
		if (e->build_state == Entity::GROWING) {
			growing.push_back(e);
		} else if (e->build_state == Entity::COMPLETE && e->hp < e->max_hp) {
			damaged.push_back(e);
		}
	}
	int64_t assist_rate = (int64_t)catalog.globals["assist_rate"];
	int64_t repair_per_tick = (int64_t)catalog.globals["repair_rate"] / TICK_RATE;
	int64_t used = 0;
	size_t gi = 0, di = 0;
	for (int64_t i = 0; i < nanos; i++) {
		while (gi < growing.size() &&
				growing[gi]->build_ticks_left - Fixed::ONE - growing[gi]->assist_bonus <= 0) {
			gi += 1;
		}
		if (gi < growing.size()) {
			growing[gi]->assist_bonus += assist_rate;
			used += 1;
			continue;
		}
		while (di < damaged.size() &&
				damaged[di]->hp + Fixed::to_int(damaged[di]->heal_acc) >= damaged[di]->max_hp) {
			di += 1;
		}
		if (di < damaged.size()) {
			damaged[di]->heal_acc += repair_per_tick;
			used += 1;
		}
	}
	return used;
}

// --- worker economy ---------------------------------------------------------
void Sim::_worker_economy_system() {
	for (int64_t id : _sorted_ids()) {
		Entity *w = E(id);
		if (_is_worker(*w) && w->hp > 0) {
			_ensure_home_depot(*w);
		}
	}
	for (int64_t id : _sorted_ids()) {
		Entity *e = E(id);
		if (e->kind == Entity::STRUCTURE && _functional(e) && _is_depot(*e) && e->worker_target > 0) {
			_auto_replace_depot(*e);
		}
	}
	std::map<int64_t, int64_t> budget;
	for (int64_t id : _sorted_ids()) {
		Entity *w = E(id);
		if (!_is_worker(*w) || w->hp <= 0 || w->build_target != 0 || w->is_manual_worker()) {
			continue;
		}
		_harvest_tick(*w, budget);
	}
}

void Sim::_auto_replace_depot(Entity &depot) {
	int64_t count = 0;
	for (const Entity &w : entities) {
		if (w.hp > 0 && _is_worker(w) && w.home_depot == depot.id) {
			count += 1;
		} else if (w.kind == Entity::STRUCTURE && w.player == depot.player) {
			for (const TrainEntry &q : w.train_queue) {
				if ((int64_t)catalog.sim_of(q.type)["carry_capacity"] > 0 &&
						_queued_worker_home(w, q) == depot.id) {
					count += 1;
				}
			}
		}
	}
	if (depot.worker_target > count) {
		_queue_replacement_at(depot);
	}
}

int64_t Sim::_queued_worker_home(const Entity &structure, const TrainEntry &entry) const {
	int64_t rd = entry.replace_depot;
	if (rd != 0 && entities.find(rd) != nullptr) {
		return rd;
	}
	return _is_depot(structure) ? structure.id : _nearest_depot(structure);
}

void Sim::_apply_worker_split_to_depot(Entity &depot) {
	std::vector<int64_t> pool;
	for (int64_t id : _sorted_ids()) {
		Entity *e = E(id);
		if (e->hp > 0 && _is_worker(*e) && e->home_depot == depot.id && !e->is_manual_worker()) {
			pool.push_back(id);
		}
	}
	int64_t l = depot.eco_alloy_build;
	int64_t c = depot.eco_alloy;
	int64_t wt = depot.worker_target;
	int64_t fb = depot.eco_flux_build;
	for (size_t i = 0; i < pool.size(); i++) {
		Entity *w = E(pool[i]);
		if ((int64_t)i < l) {
			w->work_state = Entity::WS_ALLOY_BUILD;
		} else if ((int64_t)i < c) {
			w->work_state = Entity::WS_ALLOY;
		} else if ((int64_t)i < wt - fb) {
			w->work_state = Entity::WS_FLUX;
		} else if ((int64_t)i < wt) {
			w->work_state = Entity::WS_FLUX_BUILD;
		} else {
			w->work_state = Entity::WS_ALLOY;
		}
	}
}

int64_t Sim::_gap_fill_state(const Entity &depot) const {
	int64_t want_ab = depot.eco_alloy_build;
	int64_t want_a = maxi(0, depot.eco_alloy - depot.eco_alloy_build);
	int64_t flux_total = maxi(0, depot.worker_target - depot.eco_alloy);
	int64_t want_fb = mini(depot.eco_flux_build, flux_total);
	int64_t want_f = flux_total - want_fb;
	int64_t have_a = 0, have_ab = 0, have_f = 0, have_fb = 0;
	for (const Entity &w : entities) {
		if (w.hp > 0 && _is_worker(w) && w.home_depot == depot.id && !w.is_manual_worker()) {
			switch (w.work_state) {
				case Entity::WS_ALLOY: have_a++; break;
				case Entity::WS_ALLOY_BUILD: have_ab++; break;
				case Entity::WS_FLUX: have_f++; break;
				case Entity::WS_FLUX_BUILD: have_fb++; break;
				default: break;
			}
		}
	}
	// Largest deficit wins; ties by this fixed order (mining before build).
	int64_t cand_state[4] = {Entity::WS_ALLOY, Entity::WS_FLUX, Entity::WS_ALLOY_BUILD, Entity::WS_FLUX_BUILD};
	int64_t cand_def[4] = {want_a - have_a, want_f - have_f, want_ab - have_ab, want_fb - have_fb};
	int64_t best = Entity::WS_ALLOY;
	int64_t best_def = 0;
	for (int i = 0; i < 4; i++) {
		if (cand_def[i] > best_def) {
			best_def = cand_def[i];
			best = cand_state[i];
		}
	}
	return best;
}

void Sim::_grow_depot_target(Entity &depot) {
	int64_t old_target = depot.worker_target;
	int64_t old_alloy = depot.eco_alloy;
	int64_t old_flux = old_target - old_alloy;
	bool add_alloy;
	if (old_target > 1 && old_flux == 0 && old_alloy > 0) {
		add_alloy = true;
	} else if (old_target > 1 && old_alloy == 0 && old_flux > 0) {
		add_alloy = false;
	} else {
		add_alloy = old_alloy <= old_flux;
	}
	depot.worker_target += 1;
	if (add_alloy) {
		depot.eco_alloy += 1;
	}
}

int64_t Sim::_worker_type_for(int64_t pid) const {
	PackedInt32Array types = _trainable_units(pid);
	for (int i = 0; i < types.size(); i++) {
		if ((int64_t)catalog.sim_of(types[i])["carry_capacity"] > 0) {
			return types[i];
		}
	}
	return -1;
}

void Sim::_queue_replacement_at(Entity &depot) {
	int64_t wt = _worker_type_for(depot.player);
	if (wt < 0) {
		return;
	}
	int64_t st = 0;
	PackedInt32Array trains = catalog.sim_of(depot.type_key)["trains"];
	if ((int)depot.train_queue.size() < TRAIN_QUEUE_MAX && trains.has(wt)) {
		st = depot.id;
	} else {
		st = _train_structure_for(depot.player, wt);
	}
	if (st == 0) {
		return;
	}
	int64_t depot_id = depot.id;
	Command c;
	c.player_id = depot.player;
	c.kind = Command::TRAIN;
	c.targets = {(int32_t)st};
	c.params["type"] = wt;
	c.params["auto_replace"] = true;
	c.params["replace_depot"] = depot_id;
	_execute_train(c);
}

// --- harvest state machine --------------------------------------------------
void Sim::_harvest_tick(Entity &w, std::map<int64_t, int64_t> &budget) {
	switch (w.harvest_state) {
		case Entity::IDLE: {
			int64_t role = w.mine_role();
			if (role == 0) {
				return;
			}
			int64_t src = _pick_source(w, role);
			if (src == 0) {
				return;
			}
			w.assigned_source = src;
			w.harvest_state = Entity::TO_SOURCE;
			Entity *se = E(src);
			_move_to_entity(w, *se);
			break;
		}
		case Entity::TO_SOURCE: {
			Entity *src = E(w.assigned_source);
			if (!_valid_source(src)) {
				w.assigned_source = 0;
				w.harvest_state = Entity::IDLE;
				return;
			}
			if (!_source_matches_role(src, w.mine_role())) {
				w.assigned_source = 0;
				w.harvest_state = Entity::IDLE;
				return;
			}
			if (_within_reach(w, *src)) {
				w.harvest_state = Entity::HARVESTING;
			} else if (w.orders.is_empty()) {
				_move_to_entity(w, *src);
			}
			break;
		}
		case Entity::HARVESTING: {
			Entity *src = E(w.assigned_source);
			if (!_valid_source(src)) {
				w.harvest_state = w.carry > 0 ? Entity::TO_DEPOT : Entity::IDLE;
				if (w.carry <= 0) {
					w.assigned_source = 0;
				}
				return;
			}
			_harvest_draw(w, *src, budget);
			if (w.carry >= _carry_cap_for(w, *src)) {
				w.harvest_state = Entity::TO_DEPOT;
			}
			break;
		}
		case Entity::TO_DEPOT: {
			if (w.carry <= 0) {
				w.harvest_state = Entity::IDLE;
				return;
			}
			int64_t depot = _nearest_depot(w);
			if (depot == 0) {
				return;
			}
			Entity *d = E(depot);
			if (_within_reach(w, *d)) {
				w.harvest_state = Entity::DEPOSITING;
			} else if (w.orders.is_empty()) {
				_move_to_entity(w, *d);
			}
			break;
		}
		case Entity::DEPOSITING: {
			Player *p = players.find(w.player);
			if (p != nullptr && w.carry_kind != -1) {
				if (w.carry_kind == schema::RK_ALLOY) {
					p->alloy += w.carry;
				} else {
					p->flux += w.carry;
				}
			}
			w.carry = 0;
			w.carry_kind = -1;
			w.harvest_state = Entity::IDLE;
			break;
		}
	}
}

bool Sim::_valid_source(const Entity *src) const {
	if (src == nullptr || src->hp <= 0) {
		return false;
	}
	if (src->is_resource()) {
		if (src->amount <= 0) {
			return false;
		}
		if (src->resource_kind == schema::RK_FLUX && _siphon_on(src->id) != 0) {
			return false;
		}
		return true;
	}
	if (src->kind == Entity::STRUCTURE && (bool)catalog.sim_of(src->type_key).get("is_refinery", false) &&
			src->build_state == Entity::COMPLETE) {
		for (int32_t vid : src->linked_vents) {
			const Entity *v = entities.find(vid);
			if (v != nullptr && v->amount > 0) {
				return true;
			}
		}
	}
	return false;
}

int64_t Sim::_role_of_source(const Entity *src) const {
	if (src == nullptr) {
		return 0;
	}
	if (src->is_resource()) {
		if (src->resource_kind == schema::RK_ALLOY) {
			return 1;
		}
		if (src->resource_kind == schema::RK_FLUX) {
			return 2;
		}
	} else if ((bool)catalog.sim_of(src->type_key).get("is_refinery", false)) {
		return 2;
	}
	return 0;
}

bool Sim::_source_matches_role(const Entity *src, int64_t role) const {
	return _role_of_source(src) == role;
}

int64_t Sim::_pick_source(const Entity &w, int64_t role) const {
	if (role == 2) {
		int64_t refinery = _nearest_refinery(w);
		if (refinery != 0) {
			return refinery;
		}
	}
	int64_t best = 0;
	int64_t best_d2 = 0x7FFFFFFFFFFFFFF;
	int64_t fallback = 0;
	int64_t fallback_d2 = 0x7FFFFFFFFFFFFFF;
	for (const Entity &e : entities) {
		if (!e.is_resource()) {
			continue;
		}
		if (role == 1 && e.resource_kind != schema::RK_ALLOY) {
			continue;
		}
		if (role == 2 && e.resource_kind != schema::RK_FLUX) {
			continue;
		}
		if (!_valid_source(&e)) {
			continue;
		}
		if (!_discovered_resource(w.player, e.id)) {
			continue;
		}
		if (!_within_home_radius(e, w)) {
			continue;
		}
		int64_t d2 = _entity_dist2(w, e);
		if (d2 < fallback_d2) {
			fallback_d2 = d2;
			fallback = e.id;
		}
		if (_node_assignees(e.id, w.player) < _node_saturation(w, e)) {
			if (d2 < best_d2) {
				best_d2 = d2;
				best = e.id;
			}
		}
	}
	return best != 0 ? best : fallback;
}

bool Sim::_discovered_resource(int64_t pid, int64_t res_id) const {
	const Player *p = players.find(pid);
	if (p == nullptr) {
		return false;
	}
	return std::find(p->discovered_resources.begin(), p->discovered_resources.end(),
				   (int32_t)res_id) != p->discovered_resources.end();
}

bool Sim::_within_home_radius(const Entity &src, const Entity &w) const {
	const Entity *d = entities.find(w.home_depot);
	if (d == nullptr) {
		return true;
	}
	int64_t dx = src.x - d->x;
	int64_t dy = src.y - d->y;
	return Fixed::mul(dx, dx) + Fixed::mul(dy, dy) <= Fixed::mul(AUTO_MINE_RADIUS, AUTO_MINE_RADIUS);
}

void Sim::_ensure_home_depot(Entity &w) {
	const Entity *d = w.home_depot != 0 ? entities.find(w.home_depot) : nullptr;
	if (d != nullptr && _functional(d) && d->player == w.player &&
			(bool)catalog.sim_of(d->type_key).get("is_depot", false)) {
		return;
	}
	w.home_depot = _nearest_depot(w);
}

int64_t Sim::_nearest_refinery(const Entity &w) const {
	int64_t best = 0;
	int64_t best_d2 = 0x7FFFFFFFFFFFFFF;
	for (const Entity &e : entities) {
		if (e.kind == Entity::STRUCTURE && e.player == w.player &&
				(bool)catalog.sim_of(e.type_key).get("is_refinery", false) &&
				_valid_source(&e) && _within_home_radius(e, w)) {
			int64_t d2 = _entity_dist2(w, e);
			if (d2 < best_d2) {
				best_d2 = d2;
				best = e.id;
			}
		}
	}
	return best;
}

int64_t Sim::_node_assignees(int64_t node_id, int64_t pid) const {
	int64_t count = 0;
	for (const Entity &e : entities) {
		if (e.hp > 0 && e.player == pid && _is_worker(e) && e.assigned_source == node_id) {
			count += 1;
		}
	}
	return count;
}

int64_t Sim::_node_saturation(const Entity &w, const Entity &node) const {
	int64_t tp_per_tick = (int64_t)catalog.sim_of(node.type_key)["throughput"] / TICK_RATE;
	int64_t rate = _harvest_rate_for(w, node);
	if (rate <= 0) {
		return 1;
	}
	return maxi(1, tp_per_tick / rate);
}

int64_t Sim::_entity_dist2(const Entity &a, const Entity &b) const {
	int64_t dx = b.x - a.x;
	int64_t dy = b.y - a.y;
	return Fixed::mul(dx, dx) + Fixed::mul(dy, dy);
}

bool Sim::_within_reach(const Entity &w, const Entity &t) const {
	int64_t reach = w.radius + t.radius + HARVEST_REACH;
	int64_t dx = t.x - w.x;
	int64_t dy = t.y - w.y;
	if (absi(dx) > reach || absi(dy) > reach) {
		return false;
	}
	return Fixed::mul(dx, dx) + Fixed::mul(dy, dy) <= Fixed::mul(reach, reach);
}

int64_t Sim::_carry_cap_for(const Entity &w, const Entity &src) const {
	int64_t cap = Fixed::from_int((int64_t)catalog.sim_of(w.type_key)["carry_capacity"]);
	if (_is_raw_vent(src)) {
		return Fixed::mul(cap, (int64_t)catalog.globals["raw_flux_carry"]);
	}
	return cap;
}

bool Sim::_is_raw_vent(const Entity &src) const {
	return src.is_resource() && src.resource_kind == schema::RK_FLUX;
}

int64_t Sim::_harvest_rate_for(const Entity &w, const Entity &src) const {
	int64_t rate = (int64_t)catalog.sim_of(w.type_key)["harvest_rate"];
	if (rate <= 0) {
		rate = (int64_t)catalog.globals["harvest_rate"];
	}
	int64_t per_tick = rate / TICK_RATE;
	if (_is_raw_vent(src)) {
		per_tick = Fixed::mul(per_tick, (int64_t)catalog.globals["raw_flux_rate"]);
	}
	return per_tick;
}

void Sim::_harvest_draw(Entity &w, Entity &src, std::map<int64_t, int64_t> &budget) {
	int64_t remaining_cap = _carry_cap_for(w, src) - w.carry;
	if (remaining_cap <= 0) {
		return;
	}
	int64_t demand = mini(_harvest_rate_for(w, src), remaining_cap);
	if (demand <= 0) {
		return;
	}
	int64_t kind;
	int64_t drawn = 0;
	if (src.is_resource()) {
		kind = src.resource_kind;
		drawn = _draw_node(src, demand, budget);
	} else {
		kind = schema::RK_FLUX;
		for (int32_t vid : src.linked_vents) {
			if (demand <= 0) {
				break;
			}
			Entity *v = E(vid);
			if (v == nullptr || v->amount <= 0) {
				continue;
			}
			int64_t got = _draw_node(*v, demand, budget);
			drawn += got;
			demand -= got;
		}
	}
	if (drawn <= 0) {
		return;
	}
	w.carry += drawn;
	if (w.carry_kind == -1) {
		w.carry_kind = kind;
	}
}

int64_t Sim::_draw_node(Entity &node, int64_t demand, std::map<int64_t, int64_t> &budget) {
	auto it = budget.find(node.id);
	int64_t b = it != budget.end() ? it->second : -1;
	if (b == -1) {
		b = (int64_t)catalog.sim_of(node.type_key)["throughput"] / TICK_RATE;
	}
	int64_t draw = mini(demand, mini(b, node.amount));
	if (draw <= 0) {
		budget[node.id] = b;
		return 0;
	}
	node.amount -= draw;
	budget[node.id] = b - draw;
	return draw;
}

// --- worker build -----------------------------------------------------------
void Sim::_worker_build_system() {
	_wall_system();
	std::vector<int64_t> group_order;             // target ids in first-encounter order
	std::map<int64_t, std::vector<int64_t>> groups; // target id -> builder ids (ascending)
	for (int64_t id : _sorted_ids()) {
		Entity *w = E(id);
		if (!w->is_unit() || w->hp <= 0 || w->build_target == 0) {
			continue;
		}
		Entity *t = E(w->build_target);
		if (!_valid_build_target(t, *w)) {
			w->build_target = 0;
			continue;
		}
		if (_within_reach(*w, *t)) {
			w->orders.clear();
			if (groups.find(t->id) == groups.end()) {
				group_order.push_back(t->id);
			}
			groups[t->id].push_back(w->id);
		} else if (w->orders.is_empty()) {
			_move_to_entity(*w, *t);
		}
	}
	int64_t max_builders = (int64_t)catalog.globals["max_builders"];
	int64_t accel = (int64_t)catalog.globals["accel_cost_rate"] / TICK_RATE;
	for (int64_t tid : group_order) {
		Entity *t = E(tid);
		Player *p = players.find(t->player);
		std::vector<int64_t> &builders = groups[tid];
		for (size_t i = 0; i < builders.size(); i++) {
			if ((int64_t)i >= max_builders) {
				break;
			}
			if (i > 0) {
				if (p == nullptr || p->alloy < accel) {
					continue;
				}
				p->alloy -= accel;
			}
			_apply_builder(*E(builders[i]), *t);
		}
	}
}

bool Sim::_valid_build_target(const Entity *t, const Entity &w) const {
	if (t == nullptr || t->hp <= 0 || t->player != w.player || t->kind != Entity::STRUCTURE) {
		return false;
	}
	if (t->build_state == Entity::GROWING) {
		return true;
	}
	return t->build_state == Entity::COMPLETE && t->hp < t->max_hp;
}

void Sim::_apply_builder(const Entity &w, Entity &t) {
	if (t.build_state == Entity::GROWING) {
		t.assist_bonus += _build_rate_of(w);
	} else if (t.hp < t.max_hp) {
		t.heal_acc += _repair_rate_of(w);
	}
}

int64_t Sim::_build_rate_of(const Entity &w) const {
	int64_t rate = (int64_t)catalog.sim_of(w.type_key)["build_rate"];
	if (rate <= 0) {
		rate = (int64_t)catalog.globals["build_rate"];
	}
	return rate / TICK_RATE;
}

int64_t Sim::_repair_rate_of(const Entity &w) const {
	int64_t rate = (int64_t)catalog.sim_of(w.type_key)["repair_rate"];
	if (rate <= 0) {
		rate = (int64_t)catalog.globals["repair_rate"];
	}
	return rate / TICK_RATE;
}

// --- drawn walls ------------------------------------------------------------
void Sim::_wall_system() {
	for (Player &p : players) {
		if (p.wall_cells.empty() || p.wall_type < 0) {
			continue;
		}
		int64_t pid = p.id;
		std::vector<int32_t> kept_cells;
		std::vector<int32_t> kept_claims;
		for (size_t i = 0; i < p.wall_cells.size(); i++) {
			int64_t cell = p.wall_cells[i];
			int64_t claimer = p.wall_claims[i];
			Entity *w = claimer != 0 ? E(claimer) : nullptr;
			if (w == nullptr || !w->is_unit() || w->hp <= 0 || w->wall_target_cell != cell) {
				claimer = 0;
				w = nullptr;
			}
			if (w == nullptr) {
				Entity *pick = _nearest_available_builder(pid, cell);
				if (pick != nullptr) {
					claimer = pick->id;
					pick->wall_target_cell = cell;
					_move_to_cell(*pick, cell);
					w = E(claimer); // re-fetch (move issued no spawn, but be safe)
				}
			}
			if (w != nullptr && _within_cell_reach(*w, cell) &&
					!grid.is_blocked(cell % grid.width, cell / grid.width)) {
				int64_t w_id = w->id;
				Entity *seg = _spawn_structure_entity(pid, cell % grid.width, cell / grid.width,
						p.wall_type, false, 0);
				int64_t seg_id = seg->id;
				seg->needs_builder = true;
				// re-fetch player & worker: the spawn may have reallocated stores
				Player *pp = players.find(pid);
				pp->alloy -= Fixed::from_int((int64_t)catalog.globals["wall_cost_alloy"]);
				Entity *bw = E(w_id);
				bw->build_target = seg_id;
				bw->wall_target_cell = -1;
				continue; // drop this cell from the plan
			}
			kept_cells.push_back((int32_t)cell);
			kept_claims.push_back((int32_t)claimer);
		}
		// re-fetch player (a spawn above may have reallocated the player store?
		// players are never inserted during step, so &p is still valid, but use
		// the id form for safety).
		Player *pp = players.find(pid);
		pp->wall_cells.assign(kept_cells.begin(), kept_cells.end());
		pp->wall_claims.assign(kept_claims.begin(), kept_claims.end());
		if (pp->wall_cells.empty()) {
			pp->wall_type = -1;
		}
	}
}

Entity *Sim::_nearest_available_builder(int64_t pid, int64_t cell) {
	int64_t cx = grid.cell_center(cell % grid.width);
	int64_t cy = grid.cell_center(cell / grid.width);
	Entity *best = nullptr;
	int64_t best_tier = 1;
	int64_t best_d2 = 0x7FFFFFFFFFFFFFF;
	for (int64_t id : _sorted_ids()) {
		Entity *w = E(id);
		if (!w->is_unit() || w->hp <= 0 || w->player != pid || !_is_worker(*w)) {
			continue;
		}
		if (w->is_manual_worker()) {
			continue;
		}
		if (w->build_target != 0 || w->wall_target_cell != -1) {
			continue;
		}
		Entity *hd = E(w->home_depot);
		if (hd != nullptr) {
			int64_t hx = cx - hd->x;
			int64_t hy = cy - hd->y;
			if (Fixed::mul(hx, hx) + Fixed::mul(hy, hy) > Fixed::mul(AUTO_MINE_RADIUS, AUTO_MINE_RADIUS)) {
				continue;
			}
		}
		int64_t dx = cx - w->x;
		int64_t dy = cy - w->y;
		int64_t d2 = Fixed::mul(dx, dx) + Fixed::mul(dy, dy);
		int64_t tier = w->build_draftable() ? 0 : 1;
		if (tier < best_tier || (tier == best_tier && d2 < best_d2)) {
			best = w;
			best_tier = tier;
			best_d2 = d2;
		}
	}
	return best;
}

bool Sim::_within_cell_reach(const Entity &w, int64_t cell) const {
	int64_t cx = grid.cell_center(cell % grid.width);
	int64_t cy = grid.cell_center(cell / grid.width);
	int64_t reach = w.radius + SimGrid::CELL + HARVEST_REACH;
	int64_t dx = cx - w.x;
	int64_t dy = cy - w.y;
	if (absi(dx) > reach || absi(dy) > reach) {
		return false;
	}
	return Fixed::mul(dx, dx) + Fixed::mul(dy, dy) <= Fixed::mul(reach, reach);
}

} // namespace mrts
