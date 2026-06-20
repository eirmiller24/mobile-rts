// Production, structure lifecycle, regen, elimination, auras, and the read
// queries command handlers depend on — port of the corresponding families in
// sim.gd.
#include "sim/sim.h"

#include <array>
#include <map>
#include <set>
#include <vector>

#include "sim/sim_util.h"

using namespace godot;

namespace mrts {

// --- production -------------------------------------------------------------
void Sim::_production_system() {
	for (int64_t id : _sorted_ids()) {
		Entity *e = E(id);
		if (e->kind != Entity::STRUCTURE || !_functional(e) || e->train_queue.empty()) {
			continue;
		}
		if (e->train_queue[0].left > 0) {
			e->train_queue[0].left -= 1;
		}
		if (e->train_queue[0].left > 0) {
			continue;
		}
		int64_t cell = _free_cell_near_rect(e->foot_x, e->foot_y, e->foot_w, e->foot_h);
		if (cell == -1) {
			continue;
		}
		int64_t type = e->train_queue[0].type;
		int64_t rdep = e->train_queue[0].replace_depot;
		bool e_is_depot = _is_depot(*e);
		int64_t ux = grid.cell_center(cell % grid.width);
		int64_t uy = grid.cell_center(cell / grid.width);
		int64_t uid = spawn_unit(e->player, ux, uy, type);
		// re-fetch e: spawn may have reallocated the entity store.
		e = E(id);
		Entity *nw = E(uid);
		if (_is_worker(*nw)) {
			int64_t hd = rdep;
			nw->home_depot = entities.find(hd) != nullptr ? hd : (e_is_depot ? e->id : _nearest_depot(*nw));
			Entity *depot = E(nw->home_depot);
			if (depot != nullptr) {
				nw->work_state = _gap_fill_state(*depot);
			}
		}
		e->train_queue.erase(e->train_queue.begin());
		if (e->rally_x != 0 || e->rally_y != 0) {
			Command rally;
			rally.player_id = e->player;
			rally.kind = Command::MOVE;
			rally.targets = {(int32_t)uid};
			rally.params["x"] = e->rally_x;
			rally.params["y"] = e->rally_y;
			rally.params["internal"] = true;
			_order_move(rally);
		}
	}
}

int64_t Sim::_free_cell_near_rect(int64_t cx, int64_t cy, int64_t w, int64_t h, int64_t max_radius) const {
	for (int64_t r = 1; r <= max_radius; r++) {
		int64_t x0 = cx - r;
		int64_t x1 = cx + w - 1 + r;
		int64_t y0 = cy - r;
		int64_t y1 = cy + h - 1 + r;
		for (int64_t x = x0; x <= x1; x++) {
			if (grid.in_bounds(x, y0) && !grid.is_blocked(x, y0)) {
				return grid.index(x, y0);
			}
			if (grid.in_bounds(x, y1) && !grid.is_blocked(x, y1)) {
				return grid.index(x, y1);
			}
		}
		for (int64_t y = y0 + 1; y < y1; y++) {
			if (grid.in_bounds(x0, y) && !grid.is_blocked(x0, y)) {
				return grid.index(x0, y);
			}
			if (grid.in_bounds(x1, y) && !grid.is_blocked(x1, y)) {
				return grid.index(x1, y);
			}
		}
	}
	return -1;
}

// --- structure lifecycle ----------------------------------------------------
void Sim::_structures_system() {
	for (int64_t id : _sorted_ids()) {
		Entity *e = E(id);
		if (e->kind != Entity::STRUCTURE || e->hp <= 0) {
			continue;
		}
		switch (e->build_state) {
			case Entity::CAPSULE: _capsule_tick(*e); break;
			case Entity::GROWING: _grow_tick(*e); break;
			case Entity::COMPLETE: _regen_tick(*e); break;
		}
	}
}

void Sim::_capsule_tick(Entity &e) {
	if (e.build_ticks_left > 0) {
		e.build_ticks_left -= Fixed::ONE;
		if (e.build_ticks_left > 0) {
			return;
		}
	}
	if (e.vent_id != 0) {
		if (_siphon_on_excluding(e.vent_id, e.id) != 0) {
			e.hp = 0;
			return;
		}
	} else {
		for (int64_t fy = e.foot_y; fy < e.foot_y + e.foot_h; fy++) {
			for (int64_t fx = e.foot_x; fx < e.foot_x + e.foot_w; fx++) {
				if (grid.is_blocked(fx, fy)) {
					e.hp = 0;
					return;
				}
			}
		}
		if (_units_on_footprint(e)) {
			return;
		}
	}
	grid.block_rect(e.foot_x, e.foot_y, e.foot_w, e.foot_h);
	e.blocks = true;
	e.build_state = Entity::GROWING;
	e.hp = maxi(1, e.max_hp / 10);
	e.build_ticks_left = Fixed::from_int((int64_t)catalog.sim_of(e.type_key)["build_time"]);
}

int64_t Sim::_siphon_on_excluding(int64_t vent_id, int64_t self_id) const {
	for (const Entity &e : entities) {
		if (e.id != self_id && e.kind == Entity::STRUCTURE && e.hp > 0 && e.vent_id == vent_id) {
			return e.id;
		}
	}
	return 0;
}

bool Sim::_units_on_footprint(const Entity &e) const {
	int64_t x0 = e.foot_x * SimGrid::CELL;
	int64_t y0 = e.foot_y * SimGrid::CELL;
	int64_t x1 = (e.foot_x + e.foot_w) * SimGrid::CELL;
	int64_t y1 = (e.foot_y + e.foot_h) * SimGrid::CELL;
	for (const Entity &u : entities) {
		if (!u.is_unit() || u.hp <= 0) {
			continue;
		}
		int64_t px = clampi(u.x, x0, x1);
		int64_t py = clampi(u.y, y0, y1);
		if (absi(u.x - px) < u.radius && absi(u.y - py) < u.radius) {
			return true;
		}
	}
	return false;
}

void Sim::_grow_tick(Entity &e) {
	int64_t total = Fixed::from_int((int64_t)catalog.sim_of(e.type_key)["build_time"]);
	int64_t autop = e.needs_builder ? 0 : Fixed::ONE;
	int64_t progress = autop + e.assist_bonus;
	e.assist_bonus = 0;
	int64_t prev = e.build_ticks_left;
	e.build_ticks_left = maxi(0, prev - progress);
	e.hp = mini(e.max_hp,
			e.hp + _ramp_hp(e.max_hp, total, e.build_ticks_left) - _ramp_hp(e.max_hp, total, prev));
	if (e.build_ticks_left == 0) {
		e.build_state = Entity::COMPLETE;
		_on_structure_complete(e);
	}
}

int64_t Sim::_ramp_hp(int64_t max_hp, int64_t total, int64_t left) const {
	int64_t base = maxi(1, max_hp / 10);
	if (total <= 0) {
		return max_hp;
	}
	return base + (max_hp - base) * (total - left) / total;
}

void Sim::_regen_tick(Entity &e) {
	if (e.hp >= e.max_hp) {
		e.heal_acc = 0;
		return;
	}
	e.heal_acc += _eff_hp_regen(e) / TICK_RATE;
	if (e.heal_acc >= Fixed::ONE) {
		int64_t whole = Fixed::to_int(e.heal_acc);
		e.hp = mini(e.max_hp, e.hp + whole);
		e.heal_acc -= Fixed::from_int(whole);
	}
}

// --- elimination ------------------------------------------------------------
void Sim::_check_elimination() {
	std::map<int64_t, bool> has_main;
	for (const Entity &e : entities) {
		if (e.kind == Entity::STRUCTURE && _functional(&e) &&
				(bool)catalog.sim_of(e.type_key).get("is_main", false)) {
			has_main[e.player] = true;
		}
	}
	for (Player &p : players) {
		bool hm = has_main.count(p.id) && has_main[p.id];
		if (hm) {
			p.had_main = true;
		} else if (p.had_main && p.eliminated_tick == -1) {
			p.eliminated_tick = tick;
		}
	}
}

// --- auras ------------------------------------------------------------------
void Sim::_rebuild_aura_index() {
	_aura_sources.clear();
	for (int64_t id : _sorted_ids()) {
		Entity *e = E(id);
		if (!_functional(e)) {
			continue;
		}
		PackedInt32Array abilities = _abilities_of(*e);
		for (int i = 0; i < abilities.size(); i++) {
			int64_t ak = abilities[i];
			Dictionary ab = catalog.sim_of(ak);
			if ((int64_t)ab["ability_kind"] != schema::AURA) {
				continue;
			}
			_aura_sources[e->player][ak].push_back({e->id, e->x, e->y, (int64_t)ab["radius"]});
		}
	}
}

bool Sim::_in_aura(int64_t player, int64_t ability_key, int64_t x, int64_t y) const {
	auto pit = _aura_sources.find(player);
	if (pit == _aura_sources.end()) {
		return false;
	}
	auto ait = pit->second.find(ability_key);
	if (ait == pit->second.end()) {
		return false;
	}
	for (const auto &src : ait->second) {
		if (_circle_covers(src[1], src[2], src[3], x, y)) {
			return true;
		}
	}
	return false;
}

bool Sim::_in_flagged_aura(int64_t player, const char *flag, int64_t x, int64_t y) const {
	PackedInt32Array aks = catalog.abilities_with_flag(String(flag));
	for (int i = 0; i < aks.size(); i++) {
		if (_in_aura(player, aks[i], x, y)) {
			return true;
		}
	}
	return false;
}

int64_t Sim::_eff_damage_taken(const Entity &e) const {
	int64_t best = e.damage_taken;
	std::vector<int64_t> vals;
	_modifier_values(e, "damage_taken", vals);
	for (int64_t v : vals) {
		best = mini(best, v);
	}
	return best;
}

int64_t Sim::_eff_hp_regen(const Entity &e) const {
	int64_t best = 0;
	std::vector<int64_t> vals;
	_modifier_values(e, "hp_regen", vals);
	for (int64_t v : vals) {
		best = maxi(best, v);
	}
	return best;
}

void Sim::_modifier_values(const Entity &e, const char *key, std::vector<int64_t> &out) const {
	auto pit = _aura_sources.find(e.player);
	if (pit == _aura_sources.end()) {
		return;
	}
	String skey(key);
	for (const auto &akv : pit->second) {
		int64_t ak = akv.first;
		Dictionary ab = catalog.sim_of(ak);
		Dictionary mods = ab["modifiers"];
		if (!mods.has(skey)) {
			continue;
		}
		if ((int64_t)ab["affects"] == schema::OWN_STRUCTURES && e.kind != Entity::STRUCTURE) {
			continue;
		}
		for (const auto &src : akv.second) {
			if (_circle_covers(src[1], src[2], src[3], e.x, e.y)) {
				out.push_back((int64_t)mods[skey]);
				break;
			}
		}
	}
}

// --- queries used by command handlers ---------------------------------------
void Sim::_bandwidth_of(int64_t player, int64_t &used, int64_t &provided) const {
	used = 0;
	provided = 0;
	for (const Entity &e : entities) {
		if (e.player != player || !_functional(&e)) {
			continue;
		}
		if (e.is_unit()) {
			used += (int64_t)catalog.sim_of(e.type_key)["bandwidth"];
		} else if (e.kind == Entity::STRUCTURE) {
			provided += (int64_t)catalog.sim_of(e.type_key)["bandwidth_provided"];
			for (const TrainEntry &q : e.train_queue) {
				used += (int64_t)catalog.sim_of(q.type)["bandwidth"];
			}
		}
	}
}

PackedInt32Array Sim::_trainable_units(int64_t player) const {
	std::set<int64_t> seen;
	PackedInt32Array result;
	for (int64_t id : _sorted_ids()) {
		const Entity *e = entities.find(id);
		if (e->player != player || !_functional(e) || e->kind != Entity::STRUCTURE) {
			continue;
		}
		PackedInt32Array trains = catalog.sim_of(e->type_key)["trains"];
		for (int i = 0; i < trains.size(); i++) {
			int64_t type = trains[i];
			if (seen.insert(type).second) {
				result.push_back((int32_t)type);
			}
		}
	}
	return result;
}

int64_t Sim::_train_structure_for(int64_t player, int64_t type_key) const {
	int64_t best = 0;
	int64_t best_queue = TRAIN_QUEUE_MAX;
	for (int64_t id : _sorted_ids()) {
		const Entity *e = entities.find(id);
		if (e->player != player || !_functional(e) || e->kind != Entity::STRUCTURE) {
			continue;
		}
		PackedInt32Array trains = catalog.sim_of(e->type_key)["trains"];
		if (!trains.has(type_key)) {
			continue;
		}
		if ((int64_t)e->train_queue.size() < best_queue) {
			best_queue = (int64_t)e->train_queue.size();
			best = id;
		}
	}
	return best;
}

} // namespace mrts
