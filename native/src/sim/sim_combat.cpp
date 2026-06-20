// Combat, stances, status (cooldowns/morph/burrow) — port of the
// _combat_system / _stance_system / _status_system families in sim.gd.
#include "sim/sim.h"

#include <vector>

#include "sim/proc_rng.h"
#include "sim/sim_util.h"

using namespace godot;

namespace mrts {

void Sim::_combat_system() {
	for (int64_t id : _sorted_ids()) {
		Entity *e = E(id);
		if (e->hp <= 0 || e->damage <= 0) {
			continue;
		}
		if (e->kind == Entity::STRUCTURE && e->build_state != Entity::COMPLETE) {
			continue;
		}
		if (e->is_underground() || e->morph_ticks_left > 0) {
			continue;
		}
		if (e->cooldown > 0) {
			e->cooldown -= 1;
		}
		Entity *t = e->target_id != 0 ? E(e->target_id) : nullptr;
		if (t != nullptr && (t->hp <= 0 || !_can_target(*e, *t) ||
								 !_in_range(*e, *t, e->acquire_range, false))) {
			t = nullptr;
			e->target_id = 0;
		}
		bool moving_plain = !e->orders.is_empty() &&
				(int64_t)Dictionary(e->orders[0])["kind"] == Command::MOVE;
		if (t == nullptr && !moving_plain && ((tick + e->id) & 1) == 0) {
			t = _acquire(*e);
			e->target_id = t != nullptr ? t->id : 0;
		}
		if (t != nullptr && e->cooldown == 0 && _in_range(*e, *t, e->attack_range, true)) {
			int64_t dmg = e->damage;
			if (e->crit_base > 0 && ProcRng::roll(rng, e->procs, "crit", e->crit_base, e->crit_bonus)) {
				dmg *= 2;
			}
			t->hp -= Fixed::to_int(Fixed::mul(
					Fixed::mul(Fixed::from_int(dmg), catalog.class_mul(e->attack_class, _eff_armor_class(*t))),
					_eff_damage_taken(*t)));
			e->cooldown = e->cooldown_ticks;
		}
	}
}

int64_t Sim::_eff_armor_class(const Entity &t) const {
	if (_construction_armor != -1 && t.kind == Entity::STRUCTURE && t.build_state != Entity::COMPLETE) {
		return _construction_armor;
	}
	return t.armor_class;
}

bool Sim::_engaged(const Entity &e) const {
	if (e.target_id == 0) {
		return false;
	}
	const Entity *t = entities.find(e.target_id);
	return t != nullptr && t->hp > 0 && t->player != e.player &&
			_in_range(e, *t, e.attack_range, true);
}

bool Sim::_can_target(const Entity &e, const Entity &t) const {
	if (!t.targetable || t.player == e.player) {
		return false;
	}
	if (t.is_aerial() && !e.hits_air) {
		return false;
	}
	if (t.is_underground()) {
		return false;
	}
	return true;
}

Entity *Sim::_acquire(Entity &e) {
	if (e.tactic_flags & schema::FOCUS_FIRE) {
		Entity *ff = _focus_target(e);
		if (ff != nullptr) {
			return ff;
		}
	}
	bool leashed = e.stance == schema::DEFENSIVE && e.anchor_set;
	int64_t leash = (int64_t)catalog.globals["leash_defensive"];
	Entity *best = nullptr;
	int64_t best_d2 = Fixed::mul(e.acquire_range, e.acquire_range);
	int64_t reach = (e.acquire_range >> BUCKET_SHIFT) + 1;
	for (int64_t nid : _bucket_neighbors(e, reach, 0)) {
		Entity *n = E(nid);
		if (n->hp <= 0 || !_can_target(e, *n)) {
			continue;
		}
		if (leashed && !_within_dist(e.anchor_x, e.anchor_y, n->x, n->y, leash)) {
			continue;
		}
		int64_t dx = n->x - e.x;
		int64_t dy = n->y - e.y;
		int64_t d2 = Fixed::mul(dx, dx) + Fixed::mul(dy, dy);
		if (d2 < best_d2 || (d2 == best_d2 && (best == nullptr || n->id < best->id))) {
			best_d2 = d2;
			best = n;
		}
	}
	return best;
}

Entity *Sim::_focus_target(Entity &e) {
	for (int64_t id : _sorted_ids()) {
		Entity *t = E(id);
		if (t->hp <= 0 || !_can_target(e, *t)) {
			continue;
		}
		if (!_in_range(e, *t, e.acquire_range, false)) {
			continue;
		}
		for (int64_t aid : _sorted_ids()) {
			Entity *a = E(aid);
			if (a->id != e.id && a->is_unit() && a->hp > 0 && a->player == e.player &&
					(a->tactic_flags & schema::FOCUS_FIRE) && a->target_id == t->id) {
				return t;
			}
		}
	}
	return nullptr;
}

bool Sim::_in_range(const Entity &e, const Entity &t, int64_t r, bool edge_to_edge) const {
	int64_t reach = edge_to_edge ? r + e.radius + t.radius : r;
	int64_t dx = t.x - e.x;
	int64_t dy = t.y - e.y;
	if (absi(dx) > reach || absi(dy) > reach) {
		return false;
	}
	return Fixed::mul(dx, dx) + Fixed::mul(dy, dy) <= Fixed::mul(reach, reach);
}

void Sim::_reap() {
	// Collect the dead (ascending id) before touching the container.
	std::vector<int64_t> dead;
	for (int64_t id : _sorted_ids()) {
		Entity *e = E(id);
		if (e->hp <= 0) {
			dead.push_back(id);
		}
	}
	// Fire unit_dies while the entities still exist, so dying_unit()/owner()/
	// unit_position() resolve (design_m5.md §5). Handlers may spawn or kill (those
	// reap next tick); they iterate their own snapshot, not `entities`.
	if (!dead.empty()) {
		triggers.fire_deaths(dead);
	}
	for (int64_t id : dead) {
		Entity *e = E(id);
		if (e == nullptr || e->hp > 0) {
			continue; // a death handler may have removed or revived it
		}
		if (e->blocks) {
			grid.unblock_rect(e->foot_x, e->foot_y, e->foot_w, e->foot_h);
		}
		entities.erase(id);
	}
}

// --- stances ----------------------------------------------------------------
void Sim::_stance_system() {
	for (int64_t id : _sorted_ids()) {
		Entity *e = E(id);
		if (!e->is_unit() || e->hp <= 0 || e->damage <= 0) {
			continue;
		}
		if (e->is_underground() || e->morph_ticks_left > 0) {
			continue;
		}
		if (!e->orders.is_empty()) {
			continue;
		}
		if (e->build_target != 0 || _is_worker(*e) || e->harvest_state != Entity::IDLE) {
			continue;
		}
		if (e->tactic_flags & schema::HOLD_POSITION) {
			continue;
		}
		Entity *t = E(e->target_id);
		bool has_target = t != nullptr && t->hp > 0 && t->player != e->player;
		if (e->stance == schema::RECKLESS) {
			if (has_target && !_in_range(*e, *t, e->attack_range, true)) {
				_step_toward(*e, t->x, t->y);
			}
		} else if (e->stance == schema::DEFENSIVE) {
			_stance_defensive(*e, t, has_target);
		}
	}
}

void Sim::_stance_defensive(Entity &e, Entity *t, bool has_target) {
	int64_t leash = (int64_t)catalog.globals["leash_defensive"];
	int64_t ax = e.anchor_set ? e.anchor_x : e.x;
	int64_t ay = e.anchor_set ? e.anchor_y : e.y;
	if (has_target && _within_dist(ax, ay, t->x, t->y, leash)) {
		if (!_in_range(e, *t, e.attack_range, true)) {
			_step_toward(e, t->x, t->y);
		}
		return;
	}
	if (e.anchor_set && !_within_dist(e.x, e.y, ax, ay, ARRIVE_DIST)) {
		_step_toward(e, ax, ay);
	}
}

void Sim::_step_toward(Entity &e, int64_t tx, int64_t ty) {
	int64_t dx = tx - e.x;
	int64_t dy = ty - e.y;
	int64_t d = _length(dx, dy);
	if (d == 0) {
		return;
	}
	if (d <= e.step) {
		e.x = tx;
		e.y = ty;
	} else {
		e.x += dx * e.step / d;
		e.y += dy * e.step / d;
	}
	e.x = clampi(e.x, e.radius, grid.world_w() - e.radius);
	e.y = clampi(e.y, e.radius, grid.world_h() - e.radius);
	_push_out_of_blocked(e);
}

// --- status -----------------------------------------------------------------
void Sim::_status_system() {
	for (int64_t id : _sorted_ids()) {
		Entity *e = E(id);
		if (!e->is_unit() || e->hp <= 0) {
			continue;
		}
		std::vector<int64_t> keys;
		for (const auto &kv : e->ability_cooldowns) {
			keys.push_back(kv.first);
		}
		for (int64_t key : keys) {
			e->ability_cooldowns[key] -= 1;
			if (e->ability_cooldowns[key] <= 0) {
				e->ability_cooldowns.erase(key);
			}
		}
		if (e->morph_ticks_left > 0) {
			e->morph_ticks_left -= 1;
			if (e->morph_ticks_left == 0) {
				e->morphed = !e->morphed;
				_apply_morph_stats(*e);
			}
		}
		if (e->is_underground()) {
			e->underground_ticks_left -= 1;
			if (e->underground_ticks_left == 0) {
				_surface(*e);
			}
		}
	}
}

void Sim::_apply_morph_stats(Entity &e) {
	Dictionary base = catalog.sim_of(e.type_key);
	Dictionary overrides;
	PackedInt32Array abilities = _abilities_of(e);
	for (int i = 0; i < abilities.size(); i++) {
		Dictionary ab = catalog.sim_of(abilities[i]);
		if ((int64_t)ab["ability_kind"] == schema::TOGGLE_MORPH) {
			overrides = ab["morphed"];
			break;
		}
	}
	Dictionary source = e.morphed ? overrides : base;
	Array fields = overrides.keys();
	for (int i = 0; i < fields.size(); i++) {
		String field = fields[i];
		Variant v = source.has(field) ? source[field] : base[field];
		if (field == "speed") {
			e.step = (int64_t)v / TICK_RATE;
		} else if (field == "damage") {
			e.damage = (int64_t)v;
		} else if (field == "attack_range") {
			e.attack_range = (int64_t)v;
		} else if (field == "acquire_range") {
			e.acquire_range = (int64_t)v;
		} else if (field == "cooldown") {
			e.cooldown_ticks = (int64_t)v;
		} else if (field == "hits_air") {
			e.hits_air = (bool)v;
		} else if (field == "radius") {
			e.radius = (int64_t)v;
		} else if (field == "sight") {
			e.sight = (int64_t)v;
		} else if (field == "armor_class") {
			e.armor_class = (int64_t)v;
		} else if (field == "attack_class") {
			e.attack_class = (int64_t)v;
		}
		// hp/crit_base/crit_bonus: not morphable
	}
}

void Sim::_surface(Entity &e) {
	int64_t cell = grid.nearest_free_cell(
			clampi(grid.cell_of(e.surface_x), 0, grid.width - 1),
			clampi(grid.cell_of(e.surface_y), 0, grid.height - 1));
	if (cell == -1) {
		e.underground_ticks_left = 1;
		return;
	}
	e.x = grid.cell_center(cell % grid.width);
	e.y = grid.cell_center(cell / grid.width);
	e.surface_x = 0;
	e.surface_y = 0;
	PackedInt32Array abilities = _abilities_of(e);
	for (int i = 0; i < abilities.size(); i++) {
		Dictionary ab = catalog.sim_of(abilities[i]);
		if ((int64_t)ab["ability_kind"] == schema::BLINK && (int64_t)ab["cooldown_time"] > 0) {
			e.ability_cooldowns[abilities[i]] = (int64_t)ab["cooldown_time"];
			break;
		}
	}
}

} // namespace mrts
