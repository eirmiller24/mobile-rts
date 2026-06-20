// Per-interaction read queries the console/placement UI and the bot consume —
// port of the corresponding read API in sim.gd (§4.11). Not per-frame batch;
// these fire on user actions / bot think-ticks.
#include "sim/sim.h"

#include <set>

#include "sim/sim_util.h"

using namespace godot;

namespace mrts {

PackedInt32Array Sim::buildable_structures(int64_t player) const {
	std::set<int64_t> seen;
	PackedInt32Array result;
	for (int64_t id : _sorted_ids()) {
		const Entity *e = entities.find(id);
		if (e->player != player || !_functional(e)) {
			continue;
		}
		PackedInt32Array abilities = _abilities_of(*e);
		for (int i = 0; i < abilities.size(); i++) {
			Dictionary ab = catalog.sim_of(abilities[i]);
			if ((int64_t)ab["ability_kind"] != schema::BUILD) {
				continue;
			}
			PackedInt32Array structures = ab["structures"];
			for (int j = 0; j < structures.size(); j++) {
				int64_t type = structures[j];
				if (seen.insert(type).second) {
					result.push_back((int32_t)type);
				}
			}
		}
	}
	return result;
}

int64_t Sim::builder_for(int64_t player, int64_t type_key, int64_t cx, int64_t cy) const {
	int64_t sx = cx >= 0 ? grid.cell_center(cx) : 0;
	int64_t sy = cy >= 0 ? grid.cell_center(cy) : 0;
	int64_t best = 0;
	int64_t best_tier = 3;
	int64_t best_d2 = 0x7FFFFFFFFFFFFFF;
	for (int64_t id : _sorted_ids()) {
		const Entity *e = entities.find(id);
		if (e->player != player || !_functional(e) || !_build_ability_for(*e, type_key)) {
			continue;
		}
		int64_t tier = 0;
		if (_is_worker(*e)) {
			if (e->is_manual_worker()) {
				tier = 2;
			} else if (!e->build_draftable()) {
				tier = 1;
			}
		}
		int64_t d2 = 0;
		if (cx >= 0) {
			int64_t dx = sx - e->x;
			int64_t dy = sy - e->y;
			d2 = Fixed::mul(dx, dx) + Fixed::mul(dy, dy);
		}
		if (tier < best_tier || (tier == best_tier && d2 < best_d2)) {
			best = id;
			best_tier = tier;
			best_d2 = d2;
		}
	}
	return best;
}

String Sim::build_block_reason(int64_t player, int64_t type_key) const {
	if (builder_for(player, type_key, -1, -1) == 0) {
		return String("no worker free to build");
	}
	const Player *p = players.find(player);
	if (p == nullptr) {
		return String();
	}
	Dictionary s = catalog.sim_of(type_key);
	if (p->alloy < Fixed::from_int((int64_t)s["cost_alloy"])) {
		return String("need {0} alloy").format(Array::make((int64_t)s["cost_alloy"]));
	}
	if (p->flux < Fixed::from_int((int64_t)s["cost_flux"])) {
		return String("need {0} flux").format(Array::make((int64_t)s["cost_flux"]));
	}
	return String();
}

PackedInt32Array Sim::trainable_units(int64_t player) const {
	return _trainable_units(player);
}

int64_t Sim::train_structure_for(int64_t player, int64_t type_key) const {
	return _train_structure_for(player, type_key);
}

PackedInt32Array Sim::stronghold_ids(int64_t player) const {
	PackedInt32Array result;
	for (int64_t id : _sorted_ids()) {
		const Entity *e = entities.find(id);
		if (e->player == player && _functional(e) && e->kind == Entity::STRUCTURE &&
				(int64_t)catalog.sim_of(e->type_key)["nano_pool"] > 0) {
			result.push_back((int32_t)id);
		}
	}
	return result;
}

PackedInt32Array Sim::depot_ids(int64_t player) const {
	PackedInt32Array result;
	for (int64_t id : _sorted_ids()) {
		const Entity *e = entities.find(id);
		if (e->player == player && _functional(e) && _is_depot(*e)) {
			result.push_back((int32_t)id);
		}
	}
	return result;
}

Dictionary Sim::depot_economy(int64_t depot_id) const {
	Dictionary d;
	const Entity *dep = entities.find(depot_id);
	if (dep == nullptr || !_is_depot(*dep)) {
		return d;
	}
	int64_t live = 0;
	for (const Entity &w : entities) {
		if (w.hp > 0 && _is_worker(w) && w.home_depot == depot_id) {
			live += 1;
		}
	}
	d["target"] = dep->worker_target;
	d["alloy"] = dep->eco_alloy;
	d["alloy_build"] = dep->eco_alloy_build;
	d["flux_build"] = dep->eco_flux_build;
	d["live"] = live;
	return d;
}

Array Sim::training_queues(int64_t player) const {
	Array result;
	for (int64_t id : _sorted_ids()) {
		const Entity *e = entities.find(id);
		if (e->player != player || e->hp <= 0 || e->kind != Entity::STRUCTURE) {
			continue;
		}
		PackedInt32Array trains = catalog.sim_of(e->type_key)["trains"];
		if (trains.is_empty()) {
			continue;
		}
		PackedInt32Array queue;
		for (const TrainEntry &q : e->train_queue) {
			queue.push_back((int32_t)q.type);
		}
		Dictionary row;
		row["id"] = id;
		row["type_key"] = e->type_key;
		row["queue"] = queue;
		row["head_left"] = e->train_queue.empty() ? 0 : e->train_queue[0].left;
		result.push_back(row);
	}
	return result;
}

Array Sim::vents() const {
	Array result;
	for (int64_t id : _sorted_ids()) {
		const Entity *e = entities.find(id);
		if (e->is_resource() && e->resource_kind == schema::RK_FLUX) {
			Dictionary v;
			v["id"] = id;
			v["cx"] = e->foot_x;
			v["cy"] = e->foot_y;
			v["w"] = e->foot_w;
			v["h"] = e->foot_h;
			v["taken"] = _siphon_on(id) != 0;
			result.push_back(v);
		}
	}
	return result;
}

int64_t Sim::vent_at(int64_t cx, int64_t cy, int64_t w, int64_t h) const {
	return _vent_at(cx, cy, w, h);
}

bool Sim::vent_taken(int64_t vent_id) const {
	return _siphon_on(vent_id) != 0;
}

bool Sim::territory_covers(int64_t player, int64_t x, int64_t y) const {
	return _in_flagged_aura(player, "territory", x, y);
}

Array Sim::flagged_aura_circles(int64_t player, const String &flag) const {
	Array circles;
	auto pit = _aura_sources.find(player);
	if (pit == _aura_sources.end()) {
		return circles;
	}
	PackedInt32Array aks = catalog.abilities_with_flag(flag);
	for (int i = 0; i < aks.size(); i++) {
		auto ait = pit->second.find(aks[i]);
		if (ait == pit->second.end()) {
			continue;
		}
		for (const auto &src : ait->second) {
			Array c;
			c.push_back(src[1]);
			c.push_back(src[2]);
			c.push_back(src[3]);
			circles.push_back(c);
		}
	}
	return circles;
}

int64_t Sim::free_cell_near_rect(int64_t cx, int64_t cy, int64_t w, int64_t h, int64_t max_radius) const {
	return _free_cell_near_rect(cx, cy, w, h, max_radius);
}

Dictionary Sim::income() const {
	Dictionary d;
	for (const auto &kv : _income) {
		Dictionary row;
		row["alloy"] = kv.second[0];
		row["flux"] = kv.second[1];
		row["assist_used"] = kv.second[2];
		row["idle_assist"] = kv.second[3];
		row["idle"] = kv.second[4];
		d[kv.first] = row;
	}
	return d;
}

PackedByteArray Sim::blocked_bytes() const {
	PackedByteArray out;
	out.resize((int64_t)grid.blocked.size());
	if (!grid.blocked.empty()) {
		uint8_t *w = out.ptrw();
		for (size_t i = 0; i < grid.blocked.size(); i++) {
			w[i] = grid.blocked[i];
		}
	}
	return out;
}

int64_t Sim::grid_tiles_w() const { return grid.tiles_w; }
int64_t Sim::grid_tiles_h() const { return grid.tiles_h; }

} // namespace mrts
