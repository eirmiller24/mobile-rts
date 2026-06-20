#include "sim/trigger_vm.h"

#include <algorithm>

#include "sim/command.h"
#include "sim/sim.h"
#include "sim/sim_util.h"

using namespace godot;

namespace mrts {

using namespace tir;

// --- small relation helpers (no team system yet: self=ally, distinct-and-real=enemy)
static bool rel_enemy(int64_t a, int64_t b) {
	return a != b && a != 0 && b != 0;
}
static bool rel_ally(int64_t a, int64_t b) {
	return a == b;
}

bool TriggerVM::passes_filter(const Value &filter, int64_t id) const {
	const Entity *e = _sim->entities.find(id);
	if (e == nullptr || e->is_resource()) {
		return false;
	}
	int kind = (int)filter.a;
	int64_t arg = filter.b;
	switch (kind) {
		case FK_ANY: return true;
		case FK_ALIVE: return e->hp > 0;
		case FK_IS_STRUCTURE: return e->kind == Entity::STRUCTURE;
		case FK_IS_UNIT: return e->kind == Entity::UNIT;
		case FK_ENEMY_OF: return rel_enemy(arg, e->player);
		case FK_ALLY_OF: return rel_ally(arg, e->player);
		case FK_OWNED_BY: return e->player == arg;
		case FK_OF_TYPE: return e->type_key == arg;
	}
	return true;
}

Value TriggerVM::call_builtin(int id, const std::vector<Value> &a, Frame &f) {
	const Value VOID = {T_VOID, 0, 0, nullptr};
	switch (id) {
		// --- math / core ---
		case B_MIN: return Value::int_v(a[0].a < a[1].a ? a[0].a : a[1].a);
		case B_MAX: return Value::int_v(a[0].a > a[1].a ? a[0].a : a[1].a);
		case B_ABS: return Value::int_v(a[0].a < 0 ? -a[0].a : a[0].a);
		case B_CLAMP: {
			int64_t v = a[0].a, lo = a[1].a, hi = a[2].a;
			return Value::int_v(v < lo ? lo : (v > hi ? hi : v));
		}
		case B_RANDOM_INT: {
			int64_t lo = a[0].a, hi = a[1].a;
			if (hi < lo) {
				return Value::int_v(lo);
			}
			return Value::int_v(_sim->rng.randi_range(lo, hi));
		}
		case B_TO_FIXED: return Value::fixed_v(Fixed::from_int(a[0].a));
		case B_FLOOR: return Value::int_v(Fixed::to_int(Fixed::floor(a[0].a)));
		case B_ROUND: return Value::int_v(Fixed::to_int(Fixed::round(a[0].a)));
		case B_RANDOM_FIXED: {
			int64_t lo = a[0].a, hi = a[1].a;
			if (hi <= lo) {
				return Value::fixed_v(lo);
			}
			return Value::fixed_v(lo + Fixed::mul(hi - lo, _sim->rng.rand_fixed()));
		}

		// --- geometry ---
		case B_POINT: return Value::point_v(a[0].a, a[1].a);
		case B_POINT_X: return Value::fixed_v(a[0].a);
		case B_POINT_Y: return Value::fixed_v(a[0].b);
		case B_OFFSET: return Value::point_v(a[0].a + a[1].a, a[0].b + a[2].a);
		case B_DISTANCE: {
			int64_t dx = a[0].a - a[1].a, dy = a[0].b - a[1].b;
			return Value::fixed_v(Fixed::sqrt(Fixed::mul(dx, dx) + Fixed::mul(dy, dy)));
		}
		case B_REGION_CENTER: {
			const Region *r = _sim->region_by_id(a[0].a);
			return r ? Value::point_v(r->center_x(), r->center_y()) : Value::point_v(0, 0);
		}
		case B_REGION_RANDOM_POINT: {
			const Region *r = _sim->region_by_id(a[0].a);
			if (!r || r->max_x <= r->min_x || r->max_y <= r->min_y) {
				return Value::point_v(0, 0);
			}
			int64_t rx = r->min_x + _sim->rng.randi_range(0, r->max_x - r->min_x - 1);
			int64_t ry = r->min_y + _sim->rng.randi_range(0, r->max_y - r->min_y - 1);
			return Value::point_v(rx, ry);
		}
		case B_POINT_IN_REGION: {
			const Region *r = _sim->region_by_id(a[1].a);
			return Value::bool_v(r != nullptr && r->contains(a[0].a, a[0].b));
		}
		case B_UNIT_IN_REGION: {
			const Entity *e = _sim->entities.find(a[0].a);
			const Region *r = _sim->region_by_id(a[1].a);
			return Value::bool_v(e != nullptr && r != nullptr && r->contains(e->x, e->y));
		}

		// --- entity-state queries ---
		case B_UNIT_TYPE: {
			const Entity *e = _sim->entities.find(a[0].a);
			return {T_UNITTYPE, e ? e->type_key : -1, 0, nullptr};
		}
		case B_OWNER: {
			const Entity *e = _sim->entities.find(a[0].a);
			return {T_PLAYER, e ? e->player : 0, 0, nullptr};
		}
		case B_IS_ALIVE: {
			const Entity *e = _sim->entities.find(a[0].a);
			return Value::bool_v(e != nullptr && e->hp > 0);
		}
		case B_UNIT_HP: {
			const Entity *e = _sim->entities.find(a[0].a);
			return Value::int_v(e ? e->hp : 0);
		}
		case B_UNIT_MAX_HP: {
			const Entity *e = _sim->entities.find(a[0].a);
			return Value::int_v(e ? e->max_hp : 0);
		}
		case B_UNIT_POSITION: {
			const Entity *e = _sim->entities.find(a[0].a);
			return e ? Value::point_v(e->x, e->y) : Value::point_v(0, 0);
		}
		case B_IS_STRUCTURE: {
			const Entity *e = _sim->entities.find(a[0].a);
			return Value::bool_v(e != nullptr && e->kind == Entity::STRUCTURE);
		}
		case B_IS_UNIT: {
			const Entity *e = _sim->entities.find(a[0].a);
			return Value::bool_v(e != nullptr && e->kind == Entity::UNIT);
		}
		case B_BUILD_STATE: {
			const Entity *e = _sim->entities.find(a[0].a);
			return {T_BUILD_STATE, e ? e->build_state : Entity::COMPLETE, 0, nullptr};
		}
		case B_UNIT_STANCE: {
			const Entity *e = _sim->entities.find(a[0].a);
			return {T_STANCE, e ? e->stance : 0, 0, nullptr};
		}

		// --- event-context queries (read the running handler's subject) ---
		case B_TRIGGERING_UNIT: case B_ENTERING_UNIT: case B_DYING_UNIT:
		case B_COMPLETED_STRUCTURE: case B_CREATED_UNIT:
			return {T_UNIT, f.ctx.unit, 0, nullptr};
		case B_LEAVING_UNIT:
			return {T_UNIT, f.ctx.unit, 0, nullptr};
		case B_KILLING_UNIT:
			return {T_UNIT, f.ctx.unit2, 0, nullptr};
		case B_TRIGGERING_PLAYER:
			return {T_PLAYER, f.ctx.player, 0, nullptr};
		case B_TRIGGERING_REGION:
			return {T_REGION, f.ctx.region, 0, nullptr};
		case B_EXPIRED_TIMER:
			return {T_TIMER, f.ctx.timer, 0, nullptr};

		// --- groups ---
		case B_UNITS_IN_REGION: {
			auto g = make_group();
			const Region *r = _sim->region_by_id(a[0].a);
			if (r) {
				for (const Entity &e : _sim->entities) {
					if (!e.is_resource() && e.hp > 0 && r->contains(e.x, e.y) &&
							passes_filter(a[1], e.id)) {
						g->push_back(e.id);
					}
				}
			}
			return {T_GROUP, 0, 0, g};
		}
		case B_UNITS_OF_PLAYER: {
			auto g = make_group();
			int64_t pid = a[0].a;
			for (const Entity &e : _sim->entities) {
				if (e.player == pid && !e.is_resource() && e.hp > 0 &&
						passes_filter(a[1], e.id)) {
					g->push_back(e.id);
				}
			}
			return {T_GROUP, 0, 0, g};
		}
		case B_UNITS_IN_RANGE: {
			auto g = make_group();
			int64_t px = a[0].a, py = a[0].b, r = a[1].a;
			int64_t r2 = Fixed::mul(r, r);
			for (const Entity &e : _sim->entities) {
				if (e.is_resource() || e.hp <= 0) {
					continue;
				}
				int64_t dx = e.x - px, dy = e.y - py;
				if (Fixed::mul(dx, dx) + Fixed::mul(dy, dy) <= r2 &&
						passes_filter(a[2], e.id)) {
					g->push_back(e.id);
				}
			}
			return {T_GROUP, 0, 0, g};
		}
		case B_GROUP_SIZE:
			return Value::int_v(a[0].grp ? (int64_t)a[0].grp->size() : 0);
		case B_GROUP_CONTAINS: {
			if (!a[0].grp) {
				return Value::bool_v(false);
			}
			return Value::bool_v(std::find(a[0].grp->begin(), a[0].grp->end(), a[1].a) !=
					a[0].grp->end());
		}
		case B_RANDOM_UNIT_IN: {
			if (!a[0].grp || a[0].grp->empty()) {
				return {T_UNIT, 0, 0, nullptr};
			}
			int64_t i = _sim->rng.randi_range(0, (int64_t)a[0].grp->size() - 1);
			return {T_UNIT, (*a[0].grp)[i], 0, nullptr};
		}
		case B_NEAREST_UNIT: {
			int64_t px = a[0].a, py = a[0].b;
			int64_t best = 0, best_d2 = 0x7FFFFFFFFFFFFFFLL;
			for (const Entity &e : _sim->entities) {
				if (e.is_resource() || e.hp <= 0 || !passes_filter(a[1], e.id)) {
					continue;
				}
				int64_t dx = e.x - px, dy = e.y - py;
				int64_t d2 = Fixed::mul(dx, dx) + Fixed::mul(dy, dy);
				if (d2 < best_d2) {
					best_d2 = d2;
					best = e.id;
				}
			}
			return {T_UNIT, best, 0, nullptr};
		}
		case B_GROUP_ADD: {
			if (a[0].grp && std::find(a[0].grp->begin(), a[0].grp->end(), a[1].a) ==
					a[0].grp->end()) {
				// keep ascending id order
				auto it = std::lower_bound(a[0].grp->begin(), a[0].grp->end(), a[1].a);
				a[0].grp->insert(it, a[1].a);
			}
			return VOID;
		}
		case B_GROUP_REMOVE: {
			if (a[0].grp) {
				auto it = std::find(a[0].grp->begin(), a[0].grp->end(), a[1].a);
				if (it != a[0].grp->end()) {
					a[0].grp->erase(it);
				}
			}
			return VOID;
		}
		case B_GROUP_CLEAR:
			if (a[0].grp) {
				a[0].grp->clear();
			}
			return VOID;
		case B_UNITS_OF_TYPE: {
			auto g = make_group();
			int64_t tk = a[0].a;
			for (const Entity &e : _sim->entities) {
				if (e.type_key == tk && !e.is_resource() && e.hp > 0 &&
						passes_filter(a[1], e.id)) {
					g->push_back(e.id);
				}
			}
			return {T_GROUP, 0, 0, g};
		}
		case B_FIRST_UNIT_IN:
			return {T_UNIT, (a[0].grp && !a[0].grp->empty()) ? (*a[0].grp)[0] : 0, 0, nullptr};

		// --- players & economy ---
		case B_PLAYER_RESOURCE: {
			const Player *p = _sim->players.find(a[0].a);
			if (!p) {
				return Value::int_v(0);
			}
			return Value::int_v(Fixed::to_int(a[1].a == RES_ALLOY ? p->alloy : p->flux));
		}
		case B_PLAYER_UNIT_COUNT: {
			int64_t pid = a[0].a, n = 0;
			for (const Entity &e : _sim->entities) {
				if (e.player == pid && !e.is_resource() && e.hp > 0 &&
						passes_filter(a[1], e.id)) {
					n += 1;
				}
			}
			return Value::int_v(n);
		}
		case B_IS_ENEMY: return Value::bool_v(rel_enemy(a[0].a, a[1].a));
		case B_IS_ALLY: return Value::bool_v(rel_ally(a[0].a, a[1].a));
		case B_PLAYER_RELATION: {
			int64_t rel = (a[0].a == a[1].a) ? 2 /*SELF*/
					: (rel_enemy(a[0].a, a[1].a) ? 0 /*ENEMY*/ : 1 /*ALLY*/);
			return {T_RELATION, rel, 0, nullptr};
		}
		case B_IS_VISIBLE_TO:
			return Value::bool_v(_sim->is_entity_visible(a[0].a, a[1].a));

		// --- filter constructors ---
		case B_ENEMY_OF: return {T_FILTER, FK_ENEMY_OF, a[0].a, nullptr};
		case B_ALLY_OF: return {T_FILTER, FK_ALLY_OF, a[0].a, nullptr};
		case B_OWNED_BY: return {T_FILTER, FK_OWNED_BY, a[0].a, nullptr};
		case B_OF_TYPE: return {T_FILTER, FK_OF_TYPE, a[0].a, nullptr};

		// --- unit actions (god) ---
		case B_CREATE_UNIT: {
			int64_t uid = _sim->spawn_unit(a[1].a, a[2].a, a[2].b, a[0].a);
			return {T_UNIT, uid, 0, nullptr};
		}
		case B_CREATE_UNITS: {
			auto g = make_group();
			int64_t count = a[0].a;
			for (int64_t i = 0; i < count; i++) {
				int64_t uid = _sim->spawn_unit(a[2].a, a[3].a, a[3].b, a[1].a);
				g->push_back(uid);
			}
			return {T_GROUP, 0, 0, g};
		}
		case B_REMOVE_UNIT: case B_KILL_UNIT: {
			Entity *e = _sim->entities.find(a[0].a);
			if (e) {
				e->hp = 0; // reaped this tick; death effects handled by the sim
			}
			return VOID;
		}
		case B_DAMAGE_UNIT: {
			Entity *e = _sim->entities.find(a[0].a);
			if (e && e->hp > 0) {
				e->hp = maxi(0, e->hp - a[1].a); // flat (armor routing: §catalog note)
			}
			return VOID;
		}
		case B_HEAL_UNIT: {
			Entity *e = _sim->entities.find(a[0].a);
			if (e && e->hp > 0) {
				e->hp = mini(e->max_hp, e->hp + a[1].a);
			}
			return VOID;
		}
		case B_SET_UNIT_HP: {
			Entity *e = _sim->entities.find(a[0].a);
			if (e) {
				e->hp = clampi(a[1].a, 0, e->max_hp);
			}
			return VOID;
		}
		case B_SET_UNIT_POSITION: {
			Entity *e = _sim->entities.find(a[0].a);
			if (e) {
				e->x = a[1].a;
				e->y = a[1].b;
			}
			return VOID;
		}
		case B_SET_OWNER: {
			Entity *e = _sim->entities.find(a[0].a);
			if (e) {
				e->player = a[1].a;
			}
			return VOID;
		}
		case B_SET_UNIT_STANCE: {
			Entity *e = _sim->entities.find(a[0].a);
			if (e) {
				e->stance = a[1].a;
			}
			return VOID;
		}

		// --- economy actions ---
		case B_SET_RESOURCE: {
			Player *p = _sim->players.find(a[0].a);
			if (p) {
				(a[1].a == RES_ALLOY ? p->alloy : p->flux) = Fixed::from_int(a[2].a);
			}
			return VOID;
		}
		case B_ADD_RESOURCE: {
			Player *p = _sim->players.find(a[0].a);
			if (p) {
				(a[1].a == RES_ALLOY ? p->alloy : p->flux) += Fixed::from_int(a[2].a);
			}
			return VOID;
		}

		// --- order bridge (issue SimCommands like a player would) ---
		case B_ORDER_MOVE: return order_unit(a[0].a, Command::MOVE, a[1].a, a[1].b);
		case B_ORDER_ATTACK_MOVE: return order_unit(a[0].a, Command::ATTACK_MOVE, a[1].a, a[1].b);
		case B_ORDER_PATROL: return order_unit(a[0].a, Command::PATROL, a[1].a, a[1].b);
		case B_ORDER_STOP: return order_unit(a[0].a, Command::STOP, 0, 0);
		case B_ORDER_ATTACK: {
			const Entity *t = _sim->entities.find(a[1].a);
			int64_t tx = t ? t->x : 0, ty = t ? t->y : 0;
			return order_unit(a[0].a, Command::ATTACK_MOVE, tx, ty);
		}
		case B_ORDER_GROUP_MOVE:
			return order_group(a[0].grp, Command::MOVE, a[1].a, a[1].b);
		case B_ORDER_GROUP_ATTACK_MOVE:
			return order_group(a[0].grp, Command::ATTACK_MOVE, a[1].a, a[1].b);
		case B_ORDER_TRAIN: {
			const Entity *e = _sim->entities.find(a[0].a);
			if (e) {
				Command cmd;
				cmd.player_id = e->player;
				cmd.kind = Command::TRAIN;
				cmd.targets.push_back((int32_t)a[0].a);
				cmd.params["type"] = a[1].a;
				_sim->apply_command(cmd);
			}
			return VOID;
		}
		case B_SET_RALLY: {
			const Entity *e = _sim->entities.find(a[0].a);
			if (e) {
				Command cmd;
				cmd.player_id = e->player;
				cmd.kind = Command::SET_RALLY;
				cmd.targets.push_back((int32_t)a[0].a);
				cmd.params["x"] = a[1].a;
				cmd.params["y"] = a[1].b;
				_sim->apply_command(cmd);
			}
			return VOID;
		}

		// --- regions ---
		case B_MOVE_REGION: {
			Region *r = _sim->region_by_id(a[0].a);
			if (r) {
				int64_t hw = (r->max_x - r->min_x) / 2;
				int64_t hh = (r->max_y - r->min_y) / 2;
				r->min_x = a[1].a - hw;
				r->max_x = a[1].a + hw;
				r->min_y = a[1].b - hh;
				r->max_y = a[1].b + hh;
			}
			return VOID;
		}

		// --- timers ---
		case B_START_TIMER: {
			VmTimer t;
			t.id = _next_timer_id++;
			t.remaining = maxi(1, a[0].a);
			t.period = maxi(1, a[0].a);
			t.repeating = a[1].a != 0;
			t.active = true;
			_timers.push_back(t);
			return {T_TIMER, t.id, 0, nullptr};
		}
		case B_PAUSE_TIMER: case B_RESUME_TIMER: case B_DESTROY_TIMER: {
			for (VmTimer &t : _timers) {
				if (t.id == a[0].a) {
					t.active = (id == B_RESUME_TIMER);
					break;
				}
			}
			return VOID;
		}
		case B_TIMER_REMAINING: {
			for (const VmTimer &t : _timers) {
				if (t.id == a[0].a) {
					return Value::int_v(t.remaining);
				}
			}
			return Value::int_v(0);
		}

		// --- trigger control (no trigger-typed values in the slice -> inert) ---
		case B_ENABLE_TRIGGER: case B_DISABLE_TRIGGER:
			return VOID;
		case B_IS_TRIGGER_ENABLED:
			return Value::bool_v(true);

		// --- match control ---
		case B_DECLARE_VICTORY: {
			for (Player &p : _sim->players) {
				if (p.id != 0 && p.id != a[0].a && p.eliminated_tick == -1) {
					p.eliminated_tick = _sim->tick;
				}
			}
			return VOID;
		}
		case B_DECLARE_DEFEAT: {
			Player *p = _sim->players.find(a[0].a);
			if (p && p->eliminated_tick == -1) {
				p->eliminated_tick = _sim->tick;
			}
			return VOID;
		}
		case B_END_MATCH: {
			for (Player &p : _sim->players) {
				if (p.id != 0 && p.id != a[0].a && p.eliminated_tick == -1) {
					p.eliminated_tick = _sim->tick;
				}
			}
			return VOID;
		}
		case B_SET_PLAYER_ELIMINATED: {
			Player *p = _sim->players.find(a[0].a);
			if (p) {
				if (a[1].a != 0) {
					if (p->eliminated_tick == -1) {
						p->eliminated_tick = _sim->tick;
					}
				} else {
					p->eliminated_tick = -1; // revive
				}
			}
			return VOID;
		}

		// --- presentation (unhashed view queue, §3.4) ---
		case B_DISPLAY_MESSAGE:
			emit_pres({0, a[0].a, 0, 0, (int)a[1].a});
			return VOID;
		case B_PING_MINIMAP:
			emit_pres({1, a[0].a, a[1].a, a[1].b, -1});
			return VOID;
	}
	return VOID;
}

// --- order helpers -----------------------------------------------------------
Value TriggerVM::order_unit(int64_t uid, int kind, int64_t x, int64_t y) {
	const Entity *e = _sim->entities.find(uid);
	if (!e) {
		return {T_VOID, 0, 0, nullptr};
	}
	Command cmd;
	cmd.player_id = e->player;
	cmd.kind = kind;
	cmd.targets.push_back((int32_t)uid);
	if (kind != Command::STOP) {
		cmd.params["x"] = x;
		cmd.params["y"] = y;
	}
	_sim->apply_command(cmd);
	return {T_VOID, 0, 0, nullptr};
}

Value TriggerVM::order_group(const std::shared_ptr<std::vector<int64_t>> &grp,
		int kind, int64_t x, int64_t y) {
	if (!grp || grp->empty()) {
		return {T_VOID, 0, 0, nullptr};
	}
	// One command per owning player (ascending), targets ascending id.
	std::vector<int64_t> ids = *grp;
	std::sort(ids.begin(), ids.end());
	int64_t pid = -1;
	Command cmd;
	for (int64_t uid : ids) {
		const Entity *e = _sim->entities.find(uid);
		if (!e) {
			continue;
		}
		if (e->player != pid) {
			if (!cmd.targets.empty()) {
				_sim->apply_command(cmd);
			}
			cmd = Command();
			cmd.player_id = e->player;
			cmd.kind = kind;
			if (kind != Command::STOP) {
				cmd.params["x"] = x;
				cmd.params["y"] = y;
			}
			pid = e->player;
		}
		cmd.targets.push_back((int32_t)uid);
	}
	if (!cmd.targets.empty()) {
		_sim->apply_command(cmd);
	}
	return {T_VOID, 0, 0, nullptr};
}

} // namespace mrts
