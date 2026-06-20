// Command handlers — port of the _execute* / _order_move / _start_order family
// in sim.gd. All methods of mrts::Sim.
#include "sim/sim.h"

#include <algorithm>

#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/dictionary.hpp>

#include "sim/sim_util.h"

using namespace godot;

namespace mrts {

void Sim::_execute(const Command &cmd) {
	switch (cmd.kind) {
		case Command::MOVE:
		case Command::ATTACK_MOVE:
			_order_move(cmd);
			break;
		case Command::STOP:
			for (int64_t id : _own_unit_ids(cmd)) {
				Entity *e = E(id);
				e->orders.clear();
				e->path.clear();
				e->path_i = 0;
				e->goal_key = -1;
				e->target_id = 0;
				if (_is_worker(*e)) {
					e->build_target = 0;
					e->wall_target_cell = -1;
					e->harvest_state = Entity::IDLE;
					e->assigned_source = 0;
					e->work_state = Entity::WS_MANUAL;
				}
			}
			break;
		case Command::BUILD:
			_execute_build(cmd);
			break;
		case Command::ALLOCATE_ECONOMY:
			_execute_allocate(cmd);
			break;
		case Command::TRAIN:
			_execute_train(cmd);
			break;
		case Command::CANCEL:
			_execute_cancel(cmd);
			break;
		case Command::SET_RALLY:
			_execute_set_rally(cmd);
			break;
		case Command::PATROL:
			_execute_patrol(cmd);
			break;
		case Command::SET_TACTIC:
			_execute_set_tactic(cmd);
			break;
		case Command::ABILITY:
			_execute_ability(cmd);
			break;
		case Command::MINE:
			_execute_mine(cmd);
			break;
		case Command::SET_ECONOMY:
			_execute_set_economy(cmd);
			break;
		case Command::BUILD_WALL:
			_execute_build_wall(cmd);
			break;
		case Command::REPAIR:
			_execute_repair(cmd);
			break;
		case Command::DEBUG_SPAWN:
			spawn_unit(cmd.player_id, (int64_t)cmd.params.get("x", 0),
					(int64_t)cmd.params.get("y", 0), (int64_t)cmd.params.get("type", -1));
			break;
		default:
			break;
	}
}

std::vector<int64_t> Sim::_own_unit_ids(const Command &cmd) const {
	std::vector<int64_t> ts(cmd.targets.begin(), cmd.targets.end());
	std::sort(ts.begin(), ts.end());
	std::vector<int64_t> result;
	for (int64_t id : ts) {
		const Entity *e = entities.find(id);
		if (e != nullptr && e->hp > 0 && e->is_unit() && e->player == cmd.player_id) {
			result.push_back(id);
		}
	}
	return result;
}

// --- BUILD ------------------------------------------------------------------
void Sim::_execute_build(const Command &cmd) {
	Player *player = players.find(cmd.player_id);
	if (player == nullptr || cmd.targets.empty()) {
		return;
	}
	Entity *builder = E(cmd.targets[0]);
	if (!_functional(builder) || builder->player != cmd.player_id) {
		return;
	}
	int64_t type = (int64_t)cmd.params.get("type", -1);
	if (type < 0 || type >= (int64_t)catalog.kinds.size() || catalog.kind_of(type) != "structure") {
		return;
	}
	int64_t mechanic = _build_mechanic_for(*builder, type);
	if (mechanic == -1) {
		return;
	}
	Dictionary s = catalog.sim_of(type);
	int64_t w = (int64_t)s["foot_w"];
	int64_t h = (int64_t)s["foot_h"];
	int64_t cx = (int64_t)cmd.params.get("cx", -1);
	int64_t cy = (int64_t)cmd.params.get("cy", -1);
	if (cx < 0 || cy < 0 || cx + w > grid.width || cy + h > grid.height) {
		return;
	}

	if (mechanic == schema::BM_WORKER) {
		_execute_worker_build(cmd.player_id, *builder, type, cx, cy, w, h);
		return;
	}

	int64_t vent_id = 0;
	if ((bool)s["builds_on_vent"]) {
		vent_id = _vent_at(cx, cy, w, h);
		if (vent_id == 0 || _siphon_on(vent_id) != 0) {
			return;
		}
	}

	int64_t site_x = cx * SimGrid::CELL + w * SimGrid::CELL / 2;
	int64_t site_y = cy * SimGrid::CELL + h * SimGrid::CELL / 2;
	bool inside = _in_flagged_aura(cmd.player_id, "territory", site_x, site_y);
	if ((bool)s["requires_territory"] && !inside) {
		return;
	}
	int64_t cost_alloy = (int64_t)s["cost_alloy"] + (inside ? 0 : (int64_t)s["capsule_cost_alloy"]);
	int64_t cost_flux = (int64_t)s["cost_flux"];
	if (player->alloy < Fixed::from_int(cost_alloy) || player->flux < Fixed::from_int(cost_flux)) {
		return;
	}

	if (!(bool)s["builds_on_vent"]) {
		if (inside) {
			if (!grid.rect_free(cx, cy, w, h)) {
				return;
			}
		} else {
			for (int64_t fy = cy; fy < cy + h; fy++) {
				for (int64_t fx = cx; fx < cx + w; fx++) {
					if (is_cell_visible(cmd.player_id, fx, fy) && grid.is_blocked(fx, fy)) {
						return;
					}
				}
			}
		}
	}

	player->alloy -= Fixed::from_int(cost_alloy);
	player->flux -= Fixed::from_int(cost_flux);
	if (inside) {
		_spawn_structure_entity(cmd.player_id, cx, cy, type, false, vent_id);
	} else {
		_spawn_capsule(cmd.player_id, cx, cy, type, vent_id);
	}
}

bool Sim::_build_ability_for(const Entity &builder, int64_t type) const {
	return _build_mechanic_for(builder, type) != -1;
}

int64_t Sim::_build_mechanic_for(const Entity &builder, int64_t type) const {
	PackedInt32Array abilities = _abilities_of(builder);
	for (int i = 0; i < abilities.size(); i++) {
		Dictionary ab = catalog.sim_of(abilities[i]);
		if ((int64_t)ab["ability_kind"] == schema::BUILD) {
			PackedInt32Array structures = ab["structures"];
			if (structures.has(type)) {
				return (int64_t)ab["mechanic"];
			}
		}
	}
	return -1;
}

void Sim::_execute_worker_build(int64_t player_id, Entity &builder, int64_t type,
		int64_t cx, int64_t cy, int64_t w, int64_t h) {
	Player *player = players.find(player_id);
	if (player == nullptr) {
		return;
	}
	Dictionary s = catalog.sim_of(type);
	for (int64_t fy = cy; fy < cy + h; fy++) {
		for (int64_t fx = cx; fx < cx + w; fx++) {
			if (grid.is_blocked(fx, fy)) {
				return;
			}
		}
	}
	if (player->alloy < Fixed::from_int((int64_t)s["cost_alloy"]) ||
			player->flux < Fixed::from_int((int64_t)s["cost_flux"])) {
		return;
	}
	player->alloy -= Fixed::from_int((int64_t)s["cost_alloy"]);
	player->flux -= Fixed::from_int((int64_t)s["cost_flux"]);
	int64_t builder_id = builder.id;
	Entity *site = _spawn_structure_entity(player_id, cx, cy, type, false, 0);
	int64_t site_id = site->id;
	site->needs_builder = true;
	int64_t site_x = site->x, site_y = site->y;
	// re-fetch builder: the spawn may have reallocated the entity store
	Entity *b = E(builder_id);
	b->build_target = site_id;
	b->orders.clear();
	Command c;
	c.player_id = b->player;
	c.kind = Command::MOVE;
	c.targets = {(int32_t)b->id};
	c.params["x"] = site_x;
	c.params["y"] = site_y;
	c.params["internal"] = true;
	_order_move(c);
}

int64_t Sim::_vent_at(int64_t cx, int64_t cy, int64_t w, int64_t h) const {
	for (const Entity &e : entities) {
		if (e.is_resource() && e.resource_kind == schema::RK_FLUX &&
				e.foot_x == cx && e.foot_y == cy && e.foot_w == w && e.foot_h == h) {
			return e.id;
		}
	}
	return 0;
}

int64_t Sim::_siphon_on(int64_t vent_id) const {
	for (const Entity &e : entities) {
		if (e.kind == Entity::STRUCTURE && e.hp > 0 && e.vent_id == vent_id) {
			return e.id;
		}
	}
	return 0;
}

void Sim::_spawn_capsule(int64_t player, int64_t cx, int64_t cy, int64_t type_key, int64_t vent_id) {
	Dictionary s = catalog.sim_of(type_key);
	Entity e;
	e.id = _next_entity_id++;
	e.kind = Entity::STRUCTURE;
	e.type_key = type_key;
	e.player = player;
	e.foot_x = cx;
	e.foot_y = cy;
	e.foot_w = (int64_t)s["foot_w"];
	e.foot_h = (int64_t)s["foot_h"];
	e.x = cx * SimGrid::CELL + e.foot_w * SimGrid::CELL / 2;
	e.y = cy * SimGrid::CELL + e.foot_h * SimGrid::CELL / 2;
	e.radius = mini(e.foot_w, e.foot_h) * SimGrid::CELL / 2;
	_copy_combat_stats(e, s);
	e.damage = 0;
	e.hp = (int64_t)catalog.globals["capsule_hp"];
	e.build_state = Entity::CAPSULE;
	e.build_ticks_left = Fixed::from_int((int64_t)catalog.globals["capsule_time"]);
	e.vent_id = vent_id;
	entities.put(e.id, e);
}

void Sim::_execute_allocate(const Command &cmd) {
	if (cmd.targets.empty()) {
		return;
	}
	Entity *e = E(cmd.targets[0]);
	if (!_functional(e) || e->player != cmd.player_id || e->kind != Entity::STRUCTURE) {
		return;
	}
	int64_t pool = (int64_t)catalog.sim_of(e->type_key)["nano_pool"];
	if (pool <= 0) {
		return;
	}
	int64_t a = (int64_t)cmd.params.get("alloy", 0);
	int64_t f = (int64_t)cmd.params.get("flux", 0);
	int64_t sv = (int64_t)cmd.params.get("assist", 0);
	if (a < 0 || f < 0 || sv < 0 || a + f + sv > pool) {
		return;
	}
	e->nano_alloc[0] = a;
	e->nano_alloc[1] = f;
	e->nano_alloc[2] = sv;
}

// --- MOVE / ATTACK_MOVE -----------------------------------------------------
void Sim::_order_move(const Command &cmd) {
	std::vector<int64_t> ids = _own_unit_ids(cmd);
	if (ids.empty()) {
		return;
	}
	std::vector<Entity *> units;
	units.reserve(ids.size());
	for (int64_t id : ids) {
		units.push_back(E(id));
	}
	bool queued = (bool)cmd.params.get("queue", false);
	if (!(bool)cmd.params.get("internal", false)) {
		for (Entity *e : units) {
			e->build_target = 0;
			e->wall_target_cell = -1;
			if (_is_worker(*e)) {
				e->harvest_state = Entity::IDLE;
				e->assigned_source = 0;
				e->work_state = Entity::WS_MANUAL;
			}
		}
	}
	bool small = !USE_FLOW_FIELDS || (int)units.size() <= SMALL_GROUP;
	int64_t tx = clampi((int64_t)cmd.params.get("x", 0), SimGrid::CELL / 2,
			grid.world_w() - SimGrid::CELL / 2);
	int64_t ty = clampi((int64_t)cmd.params.get("y", 0), SimGrid::CELL / 2,
			grid.world_h() - SimGrid::CELL / 2);
	int64_t gcx = clampi(grid.cell_of(tx), 0, grid.width - 1);
	int64_t gcy = clampi(grid.cell_of(ty), 0, grid.height - 1);
	int64_t group_key = grid.index(gcx, gcy);
	std::vector<int64_t> slots;
	if (units.size() > 1 && grid.is_blocked(gcx, gcy)) {
		slots = _surround_slots(gcx, gcy, ids);
	}
	// (flow-field prebuild branch omitted: USE_FLOW_FIELDS=false)
	int64_t pack_rings = _isqrt((int64_t)units.size()) + 1;
	for (size_t i = 0; i < units.size(); i++) {
		Entity *e = units[i];
		Dictionary order;
		order["kind"] = cmd.kind;
		order["x"] = tx;
		order["y"] = ty;
		order["small"] = small;
		order["group"] = group_key;
		order["cluster"] = ARRIVE_DIST + e->radius * 2 * pack_rings;
		if (!slots.empty() && slots[i] != -1) {
			order["slot_x"] = grid.cell_center(slots[i] % grid.width);
			order["slot_y"] = grid.cell_center(slots[i] / grid.width);
		}
		if (queued && !e->orders.is_empty()) {
			e->orders.push_back(order);
		} else {
			e->orders.clear();
			e->orders.push_back(order);
			e->target_id = 0;
			_start_order(*e);
		}
	}
}

std::vector<int64_t> Sim::_surround_slots(int64_t gcx, int64_t gcy, const std::vector<int64_t> &unit_ids) {
	std::vector<Entity *> units;
	for (int64_t id : unit_ids) {
		units.push_back(E(id));
	}
	int64_t n_slots = mini((int64_t)units.size(), (int64_t)SLOT_MAX);
	std::vector<std::pair<int64_t, int64_t>> cand;
	int64_t r = 1;
	while ((int64_t)cand.size() < n_slots && r <= 12) {
		for (int64_t dy = -r; dy <= r; dy++) {
			for (int64_t dx = -r; dx <= r; dx++) {
				if (maxi(absi(dx), absi(dy)) != r) {
					continue;
				}
				int64_t x = gcx + dx;
				int64_t y = gcy + dy;
				if (grid.in_bounds(x, y) && !grid.is_blocked(x, y)) {
					cand.push_back({x, y});
				}
			}
		}
		r += 1;
	}
	if (cand.empty()) {
		return {};
	}
	int64_t cenx = 0, ceny = 0;
	for (Entity *e : units) {
		cenx += grid.cell_of(e->x);
		ceny += grid.cell_of(e->y);
	}
	cenx /= (int64_t)units.size();
	ceny /= (int64_t)units.size();

	std::vector<std::pair<int64_t, int64_t>> picked;
	std::vector<bool> used(cand.size(), false);
	while ((int64_t)picked.size() < n_slots) {
		int64_t best = -1;
		int64_t best_score = -(1LL << 60);
		for (size_t i = 0; i < cand.size(); i++) {
			if (used[i]) {
				continue;
			}
			int64_t score = picked.empty() ? -_cell_dist2(cand[i].first, cand[i].second, cenx, ceny)
											: _min_dist2_to(cand[i].first, cand[i].second, picked);
			if (score > best_score) {
				best = (int64_t)i;
				best_score = score;
			}
		}
		if (best == -1) {
			picked.push_back(cand[picked.size() % cand.size()]);
			continue;
		}
		used[best] = true;
		picked.push_back(cand[best]);
	}

	// units sorted by distance to goal, ties to lower index (= lower id).
	std::vector<int64_t> by_dist;
	for (size_t i = 0; i < units.size(); i++) {
		by_dist.push_back((int64_t)i);
	}
	std::sort(by_dist.begin(), by_dist.end(), [&](int64_t a, int64_t b) {
		int64_t da = _cell_dist2(grid.cell_of(units[a]->x), grid.cell_of(units[a]->y), gcx, gcy);
		int64_t db = _cell_dist2(grid.cell_of(units[b]->x), grid.cell_of(units[b]->y), gcx, gcy);
		if (da != db) {
			return da < db;
		}
		return a < b;
	});

	std::vector<int64_t> result(units.size(), -1);
	std::vector<bool> taken(picked.size(), false);
	for (int64_t k = 0; k < n_slots; k++) {
		int64_t ui = by_dist[k];
		int64_t ecx = grid.cell_of(units[ui]->x);
		int64_t ecy = grid.cell_of(units[ui]->y);
		int64_t best = -1;
		int64_t best_d = 0;
		for (size_t j = 0; j < picked.size(); j++) {
			if (taken[j]) {
				continue;
			}
			int64_t d = _cell_dist2(ecx, ecy, picked[j].first, picked[j].second);
			if (best == -1 || d < best_d) {
				best = (int64_t)j;
				best_d = d;
			}
		}
		taken[best] = true;
		result[ui] = grid.index(picked[best].first, picked[best].second);
	}
	return result;
}

int64_t Sim::_cell_dist2(int64_t ax, int64_t ay, int64_t bx, int64_t by) const {
	int64_t dx = ax - bx;
	int64_t dy = ay - by;
	return dx * dx + dy * dy;
}

int64_t Sim::_min_dist2_to(int64_t cx, int64_t cy,
		const std::vector<std::pair<int64_t, int64_t>> &picked) const {
	int64_t m = 1LL << 60;
	for (const auto &p : picked) {
		m = mini(m, _cell_dist2(cx, cy, p.first, p.second));
	}
	return m;
}

void Sim::_start_order(Entity &e) {
	e.path.clear();
	e.path_i = 0;
	e.goal_key = -1;
	e.goal_d2_best = 0x7FFFFFFFFFFFFFF;
	e.stall = 0;
	while (!e.orders.is_empty()) {
		Dictionary o = e.orders[0];
		o["x"] = clampi((int64_t)o["x"], SimGrid::CELL / 2, grid.world_w() - SimGrid::CELL / 2);
		o["y"] = clampi((int64_t)o["y"], SimGrid::CELL / 2, grid.world_h() - SimGrid::CELL / 2);
		int64_t gx = clampi(grid.cell_of((int64_t)o["x"]), 0, grid.width - 1);
		int64_t gy = clampi(grid.cell_of((int64_t)o["y"]), 0, grid.height - 1);
		int64_t goal = grid.nearest_free_cell(gx, gy);
		if (goal != -1) {
			if (goal != grid.index(gx, gy)) {
				o["x"] = grid.cell_center(goal % grid.width);
				o["y"] = grid.cell_center(goal / grid.width);
			}
			int64_t from = _cell_index_of(e);
			if (from == goal) {
				e.goal_key = goal;
				return;
			}
			if ((bool)o["small"]) {
				e.path = Pathing::theta_star(grid, from, goal);
				if (!e.path.empty()) {
					e.goal_key = goal;
					return;
				}
				if (grid.is_blocked_index(from)) {
					e.goal_key = goal;
					return;
				}
			}
			// (flow-field branch omitted: USE_FLOW_FIELDS=false)
		}
		e.orders.pop_front();
	}
}

int64_t Sim::_cell_index_of(const Entity &e) const {
	int64_t cx = clampi(grid.cell_of(e.x), 0, grid.width - 1);
	int64_t cy = clampi(grid.cell_of(e.y), 0, grid.height - 1);
	return grid.index(cx, cy);
}

// --- TRAIN / CANCEL / RALLY -------------------------------------------------
void Sim::_execute_train(const Command &cmd) {
	if (cmd.targets.empty()) {
		return;
	}
	Entity *e = E(cmd.targets[0]);
	if (!_functional(e) || e->player != cmd.player_id || e->kind != Entity::STRUCTURE) {
		return;
	}
	int64_t type = (int64_t)cmd.params.get("type", -1);
	if (type < 0 || type >= (int64_t)catalog.kinds.size() || catalog.kind_of(type) != "unit") {
		return;
	}
	PackedInt32Array trains = catalog.sim_of(e->type_key)["trains"];
	if (!trains.has(type)) {
		return;
	}
	if ((int)e->train_queue.size() >= TRAIN_QUEUE_MAX) {
		return;
	}
	Player *player = players.find(cmd.player_id);
	if (player == nullptr) {
		return;
	}
	Dictionary s = catalog.sim_of(type);
	if (player->alloy < Fixed::from_int((int64_t)s["cost_alloy"]) ||
			player->flux < Fixed::from_int((int64_t)s["cost_flux"])) {
		return;
	}
	int64_t used, provided;
	_bandwidth_of(cmd.player_id, used, provided);
	if (used + (int64_t)s["bandwidth"] > provided) {
		return;
	}
	player->alloy -= Fixed::from_int((int64_t)s["cost_alloy"]);
	player->flux -= Fixed::from_int((int64_t)s["cost_flux"]);
	TrainEntry entry;
	entry.type = type;
	entry.left = (int64_t)s["train_time"];
	entry.replace_depot = (int64_t)cmd.params.get("replace_depot", 0);
	e->train_queue.push_back(entry);
	if ((int64_t)catalog.sim_of(type)["carry_capacity"] > 0 &&
			!(bool)cmd.params.get("auto_replace", false) && _is_depot(*e)) {
		_grow_depot_target(*e);
	}
}

void Sim::_execute_cancel(const Command &cmd) {
	Player *player = players.find(cmd.player_id);
	if (player == nullptr) {
		return;
	}
	if ((bool)cmd.params.get("wall", false)) {
		for (int32_t claimer : player->wall_claims) {
			Entity *cw = E(claimer);
			if (cw != nullptr) {
				cw->wall_target_cell = -1;
			}
		}
		player->wall_cells.clear();
		player->wall_claims.clear();
		player->wall_type = -1;
		return;
	}
	if (cmd.targets.empty()) {
		return;
	}
	Entity *e = E(cmd.targets[0]);
	if (e == nullptr || e->hp <= 0 || e->player != cmd.player_id) {
		return;
	}
	if (e->kind == Entity::STRUCTURE && e->build_state != Entity::COMPLETE) {
		Dictionary s2 = catalog.sim_of(e->type_key);
		player->alloy += Fixed::from_int((int64_t)s2["cost_alloy"]) / 2;
		player->flux += Fixed::from_int((int64_t)s2["cost_flux"]) / 2;
		e->hp = 0;
		return;
	}
	int64_t index = (int64_t)cmd.params.get("index", -1);
	if (index < 0 || index >= (int64_t)e->train_queue.size()) {
		return;
	}
	Dictionary s = catalog.sim_of(e->train_queue[index].type);
	player->alloy += Fixed::from_int((int64_t)s["cost_alloy"]);
	player->flux += Fixed::from_int((int64_t)s["cost_flux"]);
	e->train_queue.erase(e->train_queue.begin() + index);
}

void Sim::_execute_set_rally(const Command &cmd) {
	if (cmd.targets.empty()) {
		return;
	}
	Entity *e = E(cmd.targets[0]);
	if (e == nullptr || e->hp <= 0 || e->player != cmd.player_id || e->kind != Entity::STRUCTURE) {
		return;
	}
	e->rally_x = clampi((int64_t)cmd.params.get("x", 0), 0, grid.world_w());
	e->rally_y = clampi((int64_t)cmd.params.get("y", 0), 0, grid.world_h());
}

// --- ABILITY ----------------------------------------------------------------
void Sim::_execute_ability(const Command &cmd) {
	int64_t ability = (int64_t)cmd.params.get("ability", -1);
	if (ability < 0 || ability >= (int64_t)catalog.kinds.size() || catalog.kind_of(ability) != "ability") {
		return;
	}
	Dictionary ab = catalog.sim_of(ability);
	if ((int64_t)ab["ability_kind"] == schema::TOGGLE_MORPH) {
		_execute_toggle_group(ability, ab, _own_unit_ids(cmd));
		return;
	}
	for (int64_t id : _own_unit_ids(cmd)) {
		Entity *e = E(id);
		if (e->is_underground() || e->morph_ticks_left > 0) {
			continue;
		}
		if (!_abilities_of(*e).has(ability)) {
			continue;
		}
		auto it = e->ability_cooldowns.find(ability);
		if (it != e->ability_cooldowns.end() && it->second > 0) {
			continue;
		}
		if ((int64_t)ab["ability_kind"] == schema::BLINK) {
			int64_t tx = clampi((int64_t)cmd.params.get("x", e->x), SimGrid::CELL / 2,
					grid.world_w() - SimGrid::CELL / 2);
			int64_t ty = clampi((int64_t)cmd.params.get("y", e->y), SimGrid::CELL / 2,
					grid.world_h() - SimGrid::CELL / 2);
			int64_t dx = tx - e->x;
			int64_t dy = ty - e->y;
			int64_t r = (int64_t)ab["range"];
			if (absi(dx) > r || absi(dy) > r ||
					Fixed::mul(dx, dx) + Fixed::mul(dy, dy) > Fixed::mul(r, r)) {
				continue;
			}
			e->underground_ticks_left = (int64_t)ab["travel_time"];
			e->surface_x = tx;
			e->surface_y = ty;
			e->orders.clear();
			e->path.clear();
			e->goal_key = -1;
			e->target_id = 0;
		}
	}
}

void Sim::_execute_toggle_group(int64_t ability, const Dictionary &ab_in,
		const std::vector<int64_t> &unit_ids) {
	Dictionary ab = ab_in;
	std::vector<Entity *> eligible;
	for (int64_t id : unit_ids) {
		Entity *e = E(id);
		if (e->is_underground() || e->morph_ticks_left > 0) {
			continue;
		}
		if (!_abilities_of(*e).has(ability)) {
			continue;
		}
		auto it = e->ability_cooldowns.find(ability);
		if (it != e->ability_cooldowns.end() && it->second > 0) {
			continue;
		}
		eligible.push_back(e);
	}
	if (eligible.empty()) {
		return;
	}
	int64_t on_count = 0;
	for (Entity *e : eligible) {
		if (e->morphed) {
			on_count += 1;
		}
	}
	bool target_on = ((int64_t)eligible.size() - on_count) >= on_count;
	for (Entity *e : eligible) {
		if (e->morphed == target_on) {
			continue;
		}
		e->morph_ticks_left = (int64_t)ab["morph_time"];
		e->orders.clear();
		e->path.clear();
		e->goal_key = -1;
		e->target_id = 0;
	}
}

// --- TACTICS / PATROL -------------------------------------------------------
void Sim::_execute_set_tactic(const Command &cmd) {
	bool has_stance = cmd.params.has("stance");
	int64_t stance = (int64_t)cmd.params.get("stance", 0);
	bool has_flags = cmd.params.has("flags");
	int64_t flags = (int64_t)cmd.params.get("flags", 0);
	for (int64_t id : _own_unit_ids(cmd)) {
		Entity *e = E(id);
		if (has_stance) {
			e->stance = stance;
			if (stance == schema::DEFENSIVE) {
				e->anchor_x = e->x;
				e->anchor_y = e->y;
				e->anchor_set = true;
			} else {
				e->anchor_set = false;
			}
		}
		if (has_flags) {
			e->tactic_flags = flags;
		}
	}
}

void Sim::_execute_patrol(const Command &cmd) {
	for (int64_t id : _own_unit_ids(cmd)) {
		Entity *e = E(id);
		e->build_target = 0;
		e->wall_target_cell = -1;
		if (_is_worker(*e)) {
			e->harvest_state = Entity::IDLE;
			e->assigned_source = 0;
			e->work_state = Entity::WS_MANUAL;
		}
		int64_t bx = clampi((int64_t)cmd.params.get("x", e->x), SimGrid::CELL / 2,
				grid.world_w() - SimGrid::CELL / 2);
		int64_t by = clampi((int64_t)cmd.params.get("y", e->y), SimGrid::CELL / 2,
				grid.world_h() - SimGrid::CELL / 2);
		int64_t gcx = clampi(grid.cell_of(bx), 0, grid.width - 1);
		int64_t gcy = clampi(grid.cell_of(by), 0, grid.height - 1);
		Dictionary order;
		order["kind"] = (int64_t)Command::ATTACK_MOVE;
		order["x"] = bx;
		order["y"] = by;
		order["small"] = true;
		order["group"] = grid.index(gcx, gcy);
		order["cluster"] = ARRIVE_DIST + e->radius * 2;
		order["patrol"] = true;
		order["ax"] = e->x;
		order["ay"] = e->y;
		order["bx"] = bx;
		order["by"] = by;
		e->orders.clear();
		e->orders.push_back(order);
		e->target_id = 0;
		_start_order(*e);
	}
}

// --- MINE / SET_ECONOMY / REPAIR --------------------------------------------
void Sim::_execute_mine(const Command &cmd) {
	Entity *node = E((int64_t)cmd.params.get("node", 0));
	int64_t role = _role_of_source(node);
	int64_t node_id = node != nullptr ? node->id : 0;
	int64_t node_x = node != nullptr ? node->x : 0;
	int64_t node_y = node != nullptr ? node->y : 0;
	for (int64_t id : _own_unit_ids(cmd)) {
		Entity *w = E(id);
		if (!_is_worker(*w)) {
			continue;
		}
		w->build_target = 0;
		if (role == 1 || role == 2) {
			int64_t hd = _nearest_depot_pos(cmd.player_id, node_x, node_y);
			if (hd != 0) {
				w->home_depot = hd;
			}
			w->work_state = role == 1 ? Entity::WS_ALLOY : Entity::WS_FLUX;
			w->assigned_source = node_id;
			if (w->carry > 0) {
				w->harvest_state = Entity::TO_DEPOT;
			} else {
				w->harvest_state = Entity::TO_SOURCE;
				Entity *nd = E(node_id);
				if (nd != nullptr) {
					_move_to_entity(*w, *nd);
				}
			}
		} else {
			int64_t depot = w->home_depot;
			if (node != nullptr && node->player == cmd.player_id && _is_depot(*node)) {
				w->home_depot = node->id;
				depot = node->id;
			}
			Entity *d = E(depot);
			w->work_state = d != nullptr ? _gap_fill_state(*d) : Entity::WS_ALLOY;
			w->assigned_source = 0;
			w->harvest_state = Entity::IDLE;
		}
	}
}

void Sim::_execute_set_economy(const Command &cmd) {
	Player *p = players.find(cmd.player_id);
	if (p == nullptr) {
		return;
	}
	p->auto_repair = (bool)cmd.params.get("auto_repair", p->auto_repair);
	if (cmd.targets.empty()) {
		return;
	}
	Entity *depot = E(cmd.targets[0]);
	if (depot == nullptr || depot->player != cmd.player_id || !_is_depot(*depot)) {
		return;
	}
	if (cmd.params.has("worker_target")) {
		depot->worker_target = maxi(0, (int64_t)cmd.params.get("worker_target", depot->worker_target));
	}
	if (cmd.params.has("alloy_side")) {
		depot->eco_alloy = clampi((int64_t)cmd.params.get("alloy_side", 0), 0, depot->worker_target);
		depot->eco_alloy_build = clampi((int64_t)cmd.params.get("alloy_build", 0), 0, depot->eco_alloy);
		depot->eco_flux_build = clampi((int64_t)cmd.params.get("flux_build", 0), 0,
				depot->worker_target - depot->eco_alloy);
	}
	_apply_worker_split_to_depot(*depot);
}

void Sim::_execute_repair(const Command &cmd) {
	Entity *t = E((int64_t)cmd.params.get("target", 0));
	if (t == nullptr || t->player != cmd.player_id || t->kind != Entity::STRUCTURE) {
		return;
	}
	int64_t t_id = t->id;
	for (int64_t id : _own_unit_ids(cmd)) {
		Entity *w = E(id);
		if (!_is_worker(*w)) {
			continue;
		}
		w->build_target = t_id;
		w->harvest_state = Entity::IDLE;
		w->assigned_source = 0;
		w->orders.clear();
		Entity *tt = E(t_id);
		_move_to_entity(*w, *tt);
	}
}

void Sim::_execute_build_wall(const Command &cmd) {
	Player *p = players.find(cmd.player_id);
	if (p == nullptr) {
		return;
	}
	int64_t type = (int64_t)cmd.params.get("type", -1);
	if (type < 0 || type >= (int64_t)catalog.kinds.size() || catalog.kind_of(type) != "structure") {
		return;
	}
	Array cells = cmd.params.get("cells", Array());
	if (cells.is_empty()) {
		return;
	}
	p->wall_type = type;
	for (int i = 0; i < cells.size(); i++) {
		int64_t c = (int64_t)cells[i];
		int64_t cx = c % grid.width;
		int64_t cy = c / grid.width;
		if (grid.in_bounds(cx, cy)) {
			p->wall_cells.push_back((int32_t)c);
			p->wall_claims.push_back(0);
		}
	}
}

void Sim::_move_to_entity(Entity &w, const Entity &t) {
	Command c;
	c.player_id = w.player;
	c.kind = Command::MOVE;
	c.targets = {(int32_t)w.id};
	c.params["x"] = t.x;
	c.params["y"] = t.y;
	c.params["internal"] = true;
	_order_move(c);
}

void Sim::_move_to_cell(Entity &w, int64_t cell) {
	Command c;
	c.player_id = w.player;
	c.kind = Command::MOVE;
	c.targets = {(int32_t)w.id};
	c.params["x"] = grid.cell_center(cell % grid.width);
	c.params["y"] = grid.cell_center(cell / grid.width);
	c.params["internal"] = true;
	_order_move(c);
}

} // namespace mrts
