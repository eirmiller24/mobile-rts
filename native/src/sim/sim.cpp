#include "sim/sim.h"

#include <algorithm>

#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/packed_string_array.hpp>
#include <godot_cpp/variant/string.hpp>
#include <godot_cpp/variant/variant.hpp>

#include "sim/sim_hash.h"
#include "sim/sim_util.h"

using namespace godot;

namespace mrts {

const std::vector<uint8_t> Sim::_empty_vision;

// ---------------------------------------------------------------------------
// Construction
// ---------------------------------------------------------------------------
void Sim::construct(int64_t seed, Object *catalog_obj, Object *map_obj) {
	rng = DRng(seed);
	catalog.from_object(catalog_obj);
	_construction_armor = catalog.construction_armor();

	int64_t tw = (int64_t)map_obj->get("tiles_w");
	int64_t th = (int64_t)map_obj->get("tiles_h");
	grid = SimGrid(tw, th);

	int64_t map_hash = (int64_t)map_obj->get("hash_value");
	_data_hash = SimHash::mix(catalog.hash_value, map_hash);

	Array map_players = map_obj->get("players");
	for (int i = 0; i < map_players.size(); i++) {
		Dictionary p = map_players[i];
		Player sp;
		sp.id = (int64_t)p["id"];
		sp.faction = SimHash::fnv_string(std::string(String(p["faction"]).utf8().get_data()));
		sp.alloy = Fixed::from_int((int64_t)p["start_alloy"]);
		sp.flux = Fixed::from_int((int64_t)p["start_flux"]);
		players.put(sp.id, sp);
	}

	Array map_objects = map_obj->get("objects");
	// Headroom so the spawn loop rarely reallocates (reference stability).
	entities.reserve(map_objects.size() + 64);
	for (int i = 0; i < map_objects.size(); i++) {
		Dictionary obj = map_objects[i];
		int64_t tk = (int64_t)obj["type_key"];
		const std::string &kind = catalog.kind_of(tk);
		if (kind == "unit") {
			spawn_unit((int64_t)obj["player"], (int64_t)obj["x"], (int64_t)obj["y"], tk);
		} else if (kind == "structure") {
			spawn_structure((int64_t)obj["player"], (int64_t)obj["cx"], (int64_t)obj["cy"],
					tk, (bool)obj["completed"]);
		} else if (kind == "resource") {
			spawn_resource((int64_t)obj["cx"], (int64_t)obj["cy"], tk);
		}
	}

	// Seed worker home depots, then each depot's economy target (design_m4 §3.2).
	for (Entity &e : entities) {
		if (_is_worker(e) && e.hp > 0) {
			e.home_depot = _nearest_depot(e);
		}
	}
	for (Entity &e : entities) {
		if (e.kind == Entity::STRUCTURE && _is_depot(e)) {
			_reseed_depot_target(e);
		}
	}
	_recompute_vision();
}

// ---------------------------------------------------------------------------
// Spawning
// ---------------------------------------------------------------------------
int64_t Sim::spawn_unit(int64_t player, int64_t x, int64_t y, int64_t type_key) {
	Dictionary s = catalog.sim_of(type_key);
	Entity e;
	e.id = _next_entity_id++;
	e.kind = Entity::UNIT;
	e.type_key = type_key;
	e.player = player;
	e.x = x;
	e.y = y;
	_copy_combat_stats(e, s);
	e.radius = (int64_t)s["radius"];
	e.step = (int64_t)s["speed"] / TICK_RATE;
	e.crit_base = (int64_t)s["crit_base"];
	e.crit_bonus = (int64_t)s["crit_bonus"];
	if (_is_worker(e)) {
		e.work_state = Entity::WS_ALLOY;
	}
	int64_t id = e.id;
	entities.put(id, e);
	return id;
}

int64_t Sim::spawn_structure(int64_t player, int64_t cx, int64_t cy, int64_t type_key, bool completed) {
	Dictionary s = catalog.sim_of(type_key);
	if (!grid.rect_free(cx, cy, (int64_t)s["foot_w"], (int64_t)s["foot_h"])) {
		return 0;
	}
	return _spawn_structure_entity(player, cx, cy, type_key, completed, 0)->id;
}

Entity *Sim::_spawn_structure_entity(int64_t player, int64_t cx, int64_t cy, int64_t type_key,
		bool completed, int64_t vent_id) {
	Dictionary s = catalog.sim_of(type_key);
	Entity &e = _place_footprint(player, cx, cy, type_key, s);
	e.kind = Entity::STRUCTURE;
	_copy_combat_stats(e, s);
	e.vent_id = vent_id;
	if (completed) {
		e.build_state = Entity::COMPLETE;
		_on_structure_complete(e);
	} else {
		e.build_state = Entity::GROWING;
		e.build_ticks_left = Fixed::from_int((int64_t)s["build_time"]);
		e.hp = maxi(1, e.max_hp / 10);
	}
	return &e;
}

int64_t Sim::spawn_resource(int64_t cx, int64_t cy, int64_t type_key) {
	Dictionary s = catalog.sim_of(type_key);
	Entity &e = _place_footprint(0, cx, cy, type_key, s);
	e.kind = Entity::RESOURCE;
	e.targetable = false;
	e.hp = 1;
	e.max_hp = 1;
	e.amount = Fixed::from_int((int64_t)s["amount"]);
	e.resource_kind = (int64_t)s["resource"];
	return e.id;
}

Entity &Sim::_place_footprint(int64_t player, int64_t cx, int64_t cy, int64_t type_key,
		const Dictionary &s_in) {
	Dictionary s = s_in;
	Entity e;
	e.id = _next_entity_id++;
	e.type_key = type_key;
	e.player = player;
	e.foot_x = cx;
	e.foot_y = cy;
	e.foot_w = (int64_t)s["foot_w"];
	e.foot_h = (int64_t)s["foot_h"];
	e.x = cx * SimGrid::CELL + e.foot_w * SimGrid::CELL / 2;
	e.y = cy * SimGrid::CELL + e.foot_h * SimGrid::CELL / 2;
	e.radius = mini(e.foot_w, e.foot_h) * SimGrid::CELL / 2;
	grid.block_rect(cx, cy, e.foot_w, e.foot_h);
	e.blocks = true;
	return entities.put(e.id, e);
}

void Sim::_copy_combat_stats(Entity &e, const Dictionary &s_in) {
	Dictionary s = s_in;
	e.hp = (int64_t)s["hp"];
	e.max_hp = (int64_t)s["hp"];
	e.damage = (int64_t)s["damage"];
	e.attack_range = (int64_t)s["attack_range"];
	e.acquire_range = (int64_t)s["acquire_range"];
	e.cooldown_ticks = (int64_t)s["cooldown"];
	e.sight = (int64_t)s["sight"];
	e.hits_air = (bool)s["hits_air"];
	e.attack_class = (int64_t)s["attack_class"];
	e.armor_class = (int64_t)s["armor_class"];
	e.damage_taken = (int64_t)s.get("damage_taken", (int64_t)Fixed::ONE);
}

void Sim::_on_structure_complete(Entity &e) {
	Dictionary s = catalog.sim_of(e.type_key);
	if ((bool)s.get("is_refinery", false)) {
		int64_t r = (int64_t)s["refinery_radius"];
		if (r <= 0) {
			r = (int64_t)catalog.globals["refinery_radius"];
		}
		e.linked_vents.clear();
		for (Entity &n : entities) {
			if (n.is_resource() && n.resource_kind == schema::RK_FLUX &&
					_circle_covers(e.x, e.y, r, n.x, n.y)) {
				e.linked_vents.push_back((int32_t)n.id);
			}
		}
	}
	int64_t pool = (int64_t)s["nano_pool"];
	if (pool > 0) {
		int64_t alloc = (int64_t)s["default_allocation"];
		switch (alloc) {
			case schema::ALLOC_ALLOY:
				e.nano_alloc[0] = pool; e.nano_alloc[1] = 0; e.nano_alloc[2] = 0; break;
			case schema::ALLOC_FLUX:
				e.nano_alloc[0] = 0; e.nano_alloc[1] = pool; e.nano_alloc[2] = 0; break;
			case schema::ALLOC_ASSIST:
				e.nano_alloc[0] = 0; e.nano_alloc[1] = 0; e.nano_alloc[2] = pool; break;
			default:
				e.nano_alloc[0] = 0; e.nano_alloc[1] = 0; e.nano_alloc[2] = 0; break;
		}
	}
}

// ---------------------------------------------------------------------------
// Predicates and lookups
// ---------------------------------------------------------------------------
bool Sim::_is_worker(const Entity &e) const {
	return e.is_unit() && ((int64_t)catalog.sim_of(e.type_key)["carry_capacity"]) > 0;
}

bool Sim::_is_depot(const Entity &e) const {
	return e.kind == Entity::STRUCTURE &&
			(bool)catalog.sim_of(e.type_key).get("is_depot", false);
}

bool Sim::_functional(const Entity *e) const {
	if (e == nullptr || e->hp <= 0 || e->is_resource()) {
		return false;
	}
	if (e->kind == Entity::STRUCTURE && e->build_state != Entity::COMPLETE) {
		return false;
	}
	return true;
}

PackedInt32Array Sim::_abilities_of(const Entity &e) const {
	if (e.type_key == -1 || e.is_resource()) {
		return PackedInt32Array();
	}
	return catalog.sim_of(e.type_key).get("abilities", PackedInt32Array());
}

int64_t Sim::_nearest_depot(const Entity &w) const {
	return _nearest_depot_pos(w.player, w.x, w.y);
}

int64_t Sim::_nearest_depot_pos(int64_t pid, int64_t x, int64_t y) const {
	int64_t best = 0;
	int64_t best_d2 = 0x7FFFFFFFFFFFFFF;
	for (const Entity &e : entities) {
		if (e.kind == Entity::STRUCTURE && e.player == pid && _functional(&e) &&
				(bool)catalog.sim_of(e.type_key).get("is_depot", false)) {
			int64_t dx = e.x - x;
			int64_t dy = e.y - y;
			int64_t d2 = Fixed::mul(dx, dx) + Fixed::mul(dy, dy);
			if (d2 < best_d2) {
				best_d2 = d2;
				best = e.id;
			}
		}
	}
	return best;
}

void Sim::_reseed_depot_target(Entity &depot) {
	int64_t alloy = 0, alloy_b = 0, flux = 0, flux_b = 0;
	for (const Entity &w : entities) {
		if (w.hp <= 0 || !_is_worker(w) || w.home_depot != depot.id || w.is_manual_worker()) {
			continue;
		}
		switch (w.work_state) {
			case Entity::WS_ALLOY: alloy++; break;
			case Entity::WS_ALLOY_BUILD: alloy_b++; break;
			case Entity::WS_FLUX: flux++; break;
			case Entity::WS_FLUX_BUILD: flux_b++; break;
			default: break;
		}
	}
	depot.worker_target = alloy + alloy_b + flux + flux_b;
	depot.eco_alloy = alloy + alloy_b;
	depot.eco_alloy_build = alloy_b;
	depot.eco_flux_build = flux_b;
}

bool Sim::_circle_covers(int64_t cx, int64_t cy, int64_t r, int64_t x, int64_t y) const {
	int64_t dx = x - cx;
	int64_t dy = y - cy;
	if (absi(dx) > r || absi(dy) > r) {
		return false;
	}
	return Fixed::mul(dx, dx) + Fixed::mul(dy, dy) <= Fixed::mul(r, r);
}

bool Sim::_within_dist(int64_t ax, int64_t ay, int64_t bx, int64_t by, int64_t r) const {
	int64_t dx = bx - ax;
	int64_t dy = by - ay;
	if (absi(dx) > r || absi(dy) > r) {
		return false;
	}
	return Fixed::mul(dx, dx) + Fixed::mul(dy, dy) <= Fixed::mul(r, r);
}

// ---------------------------------------------------------------------------
// Vision and fog
// ---------------------------------------------------------------------------
void Sim::_recompute_vision() {
	_rebuild_occluders();
	for (Player &p : players) {
		int64_t pid = p.id;
		std::vector<uint8_t> vis((size_t)(grid.tiles_w * grid.tiles_h), 0);
		for (Entity &e : entities) {
			if (e.player != pid || !_functional(&e) || e.sight <= 0) {
				continue;
			}
			if (e.is_underground()) {
				continue;
			}
			_stamp_sight(vis, e);
		}
		// Capsule detection: a detector reveals enemy aerial entities in sight.
		for (Entity &det : entities) {
			if (det.player != pid || !_functional(&det) || det.sight <= 0 ||
					!(bool)catalog.sim_of(det.type_key).get("detects_capsules", false)) {
				continue;
			}
			for (Entity &cap : entities) {
				if (cap.player == pid || !cap.is_aerial()) {
					continue;
				}
				if (_within_dist(det.x, det.y, cap.x, cap.y, det.sight)) {
					_stamp_entity_tiles(vis, cap);
				}
			}
		}
		_vision[pid] = vis;
		// Record discovered resource nodes (hashed, ascending id).
		for (Entity &res : entities) {
			if (!res.is_resource()) {
				continue;
			}
			if (std::find(p.discovered_resources.begin(), p.discovered_resources.end(),
						(int32_t)res.id) != p.discovered_resources.end()) {
				continue;
			}
			if (is_cell_visible(pid, res.foot_x + res.foot_w / 2,
						res.foot_y + res.foot_h / 2)) {
				p.discovered_resources.push_back((int32_t)res.id);
			}
		}
	}
}

void Sim::_rebuild_occluders() {
	size_t need = (size_t)(grid.tiles_w * grid.tiles_h);
	_occluders.assign(need, 0);
	_has_occluders = false;
	for (Entity &e : entities) {
		if (e.kind != Entity::STRUCTURE || e.hp <= 0 || !e.blocks) {
			continue;
		}
		int64_t h = (int64_t)catalog.sim_of(e.type_key).get("los_height", 0);
		if (h <= 0) {
			continue;
		}
		_has_occluders = true;
		for (int64_t fy = e.foot_y; fy < e.foot_y + e.foot_h; fy++) {
			for (int64_t fx = e.foot_x; fx < e.foot_x + e.foot_w; fx++) {
				int64_t tx = fx / SimGrid::PATH_SUBDIV;
				int64_t ty = fy / SimGrid::PATH_SUBDIV;
				if (tx >= 0 && ty >= 0 && tx < grid.tiles_w && ty < grid.tiles_h) {
					_occluders[ty * grid.tiles_w + tx] = (uint8_t)h;
				}
			}
		}
	}
}

void Sim::_stamp_sight(std::vector<uint8_t> &vis, const Entity &e) {
	int64_t r = e.sight;
	int64_t tx0 = maxi(0, Fixed::to_int(e.x - r));
	int64_t tx1 = mini(grid.tiles_w - 1, Fixed::to_int(e.x + r));
	int64_t ty0 = maxi(0, Fixed::to_int(e.y - r));
	int64_t ty1 = mini(grid.tiles_h - 1, Fixed::to_int(e.y + r));
	int64_t r2 = Fixed::mul(r, r);
	int64_t sx = clampi(Fixed::to_int(e.x), 0, grid.tiles_w - 1);
	int64_t sy = clampi(Fixed::to_int(e.y), 0, grid.tiles_h - 1);
	for (int64_t ty = ty0; ty <= ty1; ty++) {
		int64_t dy = ty * Fixed::ONE + Fixed::HALF - e.y;
		int64_t dy2 = Fixed::mul(dy, dy);
		int64_t row = ty * grid.tiles_w;
		for (int64_t tx = tx0; tx <= tx1; tx++) {
			int64_t dx = tx * Fixed::ONE + Fixed::HALF - e.x;
			if (Fixed::mul(dx, dx) + dy2 > r2) {
				continue;
			}
			if (_has_occluders && !_los_unoccluded(sx, sy, tx, ty)) {
				continue;
			}
			vis[row + tx] = 1;
		}
	}
}

bool Sim::_los_unoccluded(int64_t x0, int64_t y0, int64_t x1, int64_t y1) const {
	int64_t w = grid.tiles_w;
	int64_t dx = absi(x1 - x0);
	int64_t dy = absi(y1 - y0);
	int64_t x = x0;
	int64_t y = y0;
	int64_t x_inc = x1 > x0 ? 1 : -1;
	int64_t y_inc = y1 > y0 ? 1 : -1;
	int64_t error = dx - dy;
	dx *= 2;
	dy *= 2;
	while (true) {
		if (x == x1 && y == y1) {
			return true;
		}
		if ((x != x0 || y != y0) && _occluders[y * w + x] > 0) {
			return false;
		}
		if (error > 0) {
			x += x_inc;
			error -= dy;
		} else if (error < 0) {
			y += y_inc;
			error += dx;
		} else {
			x += x_inc;
			y += y_inc;
			error -= dy;
			error += dx;
		}
	}
	return true;
}

void Sim::_stamp_entity_tiles(std::vector<uint8_t> &vis, const Entity &e) const {
	int64_t tx0 = clampi(Fixed::to_int(e.x - e.radius), 0, grid.tiles_w - 1);
	int64_t tx1 = clampi(Fixed::to_int(e.x + e.radius), 0, grid.tiles_w - 1);
	int64_t ty0 = clampi(Fixed::to_int(e.y - e.radius), 0, grid.tiles_h - 1);
	int64_t ty1 = clampi(Fixed::to_int(e.y + e.radius), 0, grid.tiles_h - 1);
	for (int64_t ty = ty0; ty <= ty1; ty++) {
		for (int64_t tx = tx0; tx <= tx1; tx++) {
			vis[ty * grid.tiles_w + tx] = 1;
		}
	}
}

bool Sim::is_tile_visible(int64_t player, int64_t tx, int64_t ty) const {
	if (tx < 0 || ty < 0 || tx >= grid.tiles_w || ty >= grid.tiles_h) {
		return false;
	}
	auto it = _vision.find(player);
	if (it == _vision.end() || it->second.empty()) {
		return false;
	}
	return it->second[ty * grid.tiles_w + tx] == 1;
}

bool Sim::is_cell_visible(int64_t player, int64_t cx, int64_t cy) const {
	return is_tile_visible(player, cx / SimGrid::PATH_SUBDIV, cy / SimGrid::PATH_SUBDIV);
}

const std::vector<uint8_t> &Sim::vision_of(int64_t player) const {
	auto it = _vision.find(player);
	return it == _vision.end() ? _empty_vision : it->second;
}

// ---------------------------------------------------------------------------
// Hash
// ---------------------------------------------------------------------------
int64_t Sim::state_hash() const {
	int64_t h = 17;
	h = SimHash::mix(h, _data_hash);
	h = SimHash::mix(h, tick);
	h = SimHash::mix(h, rng.state);
	h = SimHash::mix(h, _next_entity_id);
	h = grid.hash_into(h);
	for (const Player &p : players) {
		h = p.hash_into(h);
	}
	for (const Entity &e : entities) {
		h = e.hash_into(h);
	}
	return h;
}

// ---------------------------------------------------------------------------
// Tick driver
// ---------------------------------------------------------------------------
std::vector<int64_t> Sim::_sorted_ids() const {
	std::vector<int64_t> ids;
	ids.reserve((size_t)entities.size());
	for (const Entity &e : entities) {
		ids.push_back(e.id);
	}
	return ids; // IdVec iterates ascending id
}

void Sim::schedule(const Command &cmd, int64_t at_tick) {
	int64_t t = at_tick >= 0 ? at_tick : tick + COMMAND_DELAY;
	_command_queue[t].push_back(cmd);
}

void Sim::_execute_scheduled_commands() {
	auto it = _command_queue.find(tick);
	if (it == _command_queue.end()) {
		return;
	}
	std::vector<Command> commands = std::move(it->second);
	_command_queue.erase(it);
	std::sort(commands.begin(), commands.end(), [](const Command &a, const Command &b) {
		if (a.player_id != b.player_id) {
			return a.player_id < b.player_id;
		}
		return a.seq < b.seq;
	});
	for (const Command &c : commands) {
		_execute(c);
	}
}

// Tick order (design_m3.md §4). Flow-field builds (_run_flow_builds) are omitted:
// USE_FLOW_FIELDS=false, so no builds are ever queued.
void Sim::step() {
	_rebuild_aura_index();
	_execute_scheduled_commands();
	_economy_system();
	_worker_economy_system();
	_worker_build_system();
	_production_system();
	_movement_system();
	_combat_system();
	_stance_system();
	_status_system();
	_structures_system();
	_reap();
	_check_elimination();
	tick += 1;
	if (tick % VISION_PERIOD == 0) {
		_recompute_vision();
	}
}

bool Sim::match_over() const {
	int64_t real = 0, alive = 0;
	for (const Player &p : players) {
		if (p.id == 0) {
			continue;
		}
		real += 1;
		if (p.eliminated_tick == -1) {
			alive += 1;
		}
	}
	return real >= 2 && alive <= 1;
}

int64_t Sim::match_winner() const {
	if (!match_over()) {
		return 0;
	}
	int64_t winner = 0, alive = 0;
	for (const Player &p : players) {
		if (p.id == 0) {
			continue;
		}
		if (p.eliminated_tick == -1) {
			alive += 1;
			winner = p.id;
		}
	}
	return alive == 1 ? winner : 0;
}

} // namespace mrts
