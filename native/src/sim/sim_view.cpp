// Batch view read API (design_m5.md §2.3). The view crosses the boundary O(1)
// times per tick: view_snapshot() returns parallel packed arrays of every live
// entity (ascending id) with render visibility pre-baked, instead of hundreds of
// per-entity property reads. The remaining reads (fog/resources/bandwidth/match)
// are likewise single-call.
#include "sim/sim.h"

#include "sim/sim_util.h"

using namespace godot;

namespace mrts {

bool Sim::_is_entity_visible(int64_t player, const Entity &e) const {
	if (e.hp <= 0) {
		return false;
	}
	if (e.player == player) {
		return true;
	}
	if (e.is_aerial()) {
		for (const Entity &s : entities) {
			if (s.player == player && _functional(&s) && s.sight > 0 &&
					_within_dist(s.x, s.y, e.x, e.y, s.sight)) {
				return true;
			}
		}
		return false;
	}
	return is_tile_visible(player, Fixed::to_int(e.x), Fixed::to_int(e.y));
}

bool Sim::is_entity_visible(int64_t player, int64_t entity_id) const {
	const Entity *e = entities.find(entity_id);
	return e != nullptr && _is_entity_visible(player, *e);
}

// flags bit layout (keep in sync with the view consumer):
//   bit0 morphed   bit1 underground   bit2 render-visible-to-viewer
//   bit3 is_unit   bit4 is_resource   bit5 is_structure
Dictionary Sim::view_snapshot(int64_t viewer) const {
	PackedInt32Array ids, type_key, player, hp, max_hp, foot_x, foot_y, foot_w, foot_h, flags;
	PackedInt32Array resource_kind, nano_alloy, nano_flux, nano_assist;
	PackedByteArray kind, build_state;
	PackedInt64Array x, y, radius, amount, build_ticks_left;
	int64_t n = entities.size();
	ids.resize(n); type_key.resize(n); player.resize(n); hp.resize(n); max_hp.resize(n);
	foot_x.resize(n); foot_y.resize(n); foot_w.resize(n); foot_h.resize(n); flags.resize(n);
	resource_kind.resize(n); nano_alloy.resize(n); nano_flux.resize(n); nano_assist.resize(n);
	kind.resize(n); build_state.resize(n);
	x.resize(n); y.resize(n); radius.resize(n); amount.resize(n); build_ticks_left.resize(n);

	int i = 0;
	for (const Entity &e : entities) {
		ids[i] = (int32_t)e.id;
		type_key[i] = (int32_t)e.type_key;
		player[i] = (int32_t)e.player;
		kind[i] = (uint8_t)e.kind;
		x[i] = e.x;
		y[i] = e.y;
		radius[i] = e.radius;
		hp[i] = (int32_t)e.hp;
		max_hp[i] = (int32_t)e.max_hp;
		amount[i] = e.amount;
		build_state[i] = (uint8_t)e.build_state;
		build_ticks_left[i] = e.build_ticks_left;
		foot_x[i] = (int32_t)e.foot_x;
		foot_y[i] = (int32_t)e.foot_y;
		foot_w[i] = (int32_t)e.foot_w;
		foot_h[i] = (int32_t)e.foot_h;
		resource_kind[i] = (int32_t)e.resource_kind;
		nano_alloy[i] = (int32_t)e.nano_alloc[0];
		nano_flux[i] = (int32_t)e.nano_alloc[1];
		nano_assist[i] = (int32_t)e.nano_alloc[2];
		int32_t f = 0;
		if (e.morphed) f |= 1;
		if (e.is_underground()) f |= 2;
		if (e.player == viewer || e.is_resource() || _is_entity_visible(viewer, e)) f |= 4;
		if (e.is_unit()) f |= 8;
		if (e.is_resource()) f |= 16;
		if (e.kind == Entity::STRUCTURE) f |= 32;
		flags[i] = f;
		i++;
	}

	Dictionary d;
	d["ids"] = ids;
	d["type_key"] = type_key;
	d["player"] = player;
	d["kind"] = kind;
	d["x"] = x;
	d["y"] = y;
	d["radius"] = radius;
	d["hp"] = hp;
	d["max_hp"] = max_hp;
	d["amount"] = amount;
	d["build_state"] = build_state;
	d["build_ticks_left"] = build_ticks_left;
	d["foot_x"] = foot_x;
	d["foot_y"] = foot_y;
	d["foot_w"] = foot_w;
	d["foot_h"] = foot_h;
	d["resource_kind"] = resource_kind;
	d["nano_alloy"] = nano_alloy;
	d["nano_flux"] = nano_flux;
	d["nano_assist"] = nano_assist;
	d["flags"] = flags;
	return d;
}

PackedByteArray Sim::vision_bytes(int64_t player) const {
	const std::vector<uint8_t> &vis = vision_of(player);
	PackedByteArray out;
	out.resize((int64_t)vis.size());
	if (!vis.empty()) {
		uint8_t *w = out.ptrw();
		for (size_t k = 0; k < vis.size(); k++) {
			w[k] = vis[k];
		}
	}
	return out;
}

Dictionary Sim::resources_of(int64_t player) const {
	Dictionary d;
	const Player *p = players.find(player);
	if (p == nullptr) {
		d["alloy"] = 0;
		d["flux"] = 0;
		return d;
	}
	d["alloy"] = Fixed::to_int(p->alloy);
	d["flux"] = Fixed::to_int(p->flux);
	return d;
}

Dictionary Sim::bandwidth_of(int64_t player) const {
	int64_t used, provided;
	_bandwidth_of(player, used, provided);
	Dictionary d;
	d["used"] = used;
	d["provided"] = provided;
	return d;
}

Dictionary Sim::players_snapshot() const {
	Dictionary d;
	for (const Player &p : players) {
		Dictionary row;
		row["id"] = p.id;
		row["faction"] = p.faction;
		row["alloy"] = p.alloy;
		row["flux"] = p.flux;
		row["auto_repair"] = p.auto_repair;
		row["eliminated_tick"] = p.eliminated_tick;
		row["had_main"] = p.had_main;
		d[p.id] = row;
	}
	return d;
}

Dictionary Sim::match_result() const {
	Dictionary d;
	d["over"] = match_over();
	d["winner"] = match_winner();
	Dictionary elim;
	for (const Player &p : players) {
		if (p.id == 0) {
			continue;
		}
		elim[p.id] = p.eliminated_tick;
	}
	d["eliminated"] = elim;
	return d;
}

} // namespace mrts
