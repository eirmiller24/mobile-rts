#include "native_sim.h"

#include <godot_cpp/core/class_db.hpp>

#include "sim/drng.h"
#include "sim/fixed.h"
#include "sim/proc_rng.h"
#include "sim/sim_grid.h"
#include "sim/sim_hash.h"

using namespace godot;
using namespace mrts;

void NativeSim::_bind_methods() {
	ClassDB::bind_method(D_METHOD("construct", "seed", "catalog", "map"), &NativeSim::construct);
	ClassDB::bind_method(D_METHOD("state_hash"), &NativeSim::state_hash);
	ClassDB::bind_method(D_METHOD("get_tick"), &NativeSim::get_tick);
	ClassDB::bind_method(D_METHOD("step"), &NativeSim::step);
	ClassDB::bind_method(D_METHOD("schedule", "player_id", "kind", "targets", "params", "seq", "at_tick"),
			&NativeSim::schedule);
	ClassDB::bind_method(D_METHOD("load_triggers", "program"), &NativeSim::load_triggers);
	ClassDB::bind_method(D_METHOD("trigger_presentation"), &NativeSim::trigger_presentation);

	ClassDB::bind_method(D_METHOD("view_snapshot", "viewer"), &NativeSim::view_snapshot);
	ClassDB::bind_method(D_METHOD("vision_of", "player"), &NativeSim::vision_of);
	ClassDB::bind_method(D_METHOD("resources_of", "player"), &NativeSim::resources_of);
	ClassDB::bind_method(D_METHOD("bandwidth_of", "player"), &NativeSim::bandwidth_of);
	ClassDB::bind_method(D_METHOD("players_snapshot"), &NativeSim::players_snapshot);
	ClassDB::bind_method(D_METHOD("match_result"), &NativeSim::match_result);
	ClassDB::bind_method(D_METHOD("is_entity_visible", "player", "entity_id"), &NativeSim::is_entity_visible);
	ClassDB::bind_method(D_METHOD("is_tile_visible", "player", "tx", "ty"), &NativeSim::is_tile_visible);
	ClassDB::bind_method(D_METHOD("is_cell_visible", "player", "cx", "cy"), &NativeSim::is_cell_visible);

	ClassDB::bind_method(D_METHOD("buildable_structures", "player"), &NativeSim::buildable_structures);
	ClassDB::bind_method(D_METHOD("builder_for", "player", "type_key", "cx", "cy"), &NativeSim::builder_for);
	ClassDB::bind_method(D_METHOD("build_block_reason", "player", "type_key"), &NativeSim::build_block_reason);
	ClassDB::bind_method(D_METHOD("trainable_units", "player"), &NativeSim::trainable_units);
	ClassDB::bind_method(D_METHOD("train_structure_for", "player", "type_key"), &NativeSim::train_structure_for);
	ClassDB::bind_method(D_METHOD("stronghold_ids", "player"), &NativeSim::stronghold_ids);
	ClassDB::bind_method(D_METHOD("depot_ids", "player"), &NativeSim::depot_ids);
	ClassDB::bind_method(D_METHOD("depot_economy", "depot_id"), &NativeSim::depot_economy);
	ClassDB::bind_method(D_METHOD("training_queues", "player"), &NativeSim::training_queues);
	ClassDB::bind_method(D_METHOD("vents"), &NativeSim::vents);
	ClassDB::bind_method(D_METHOD("vent_at", "cx", "cy", "w", "h"), &NativeSim::vent_at);
	ClassDB::bind_method(D_METHOD("vent_taken", "vent_id"), &NativeSim::vent_taken);
	ClassDB::bind_method(D_METHOD("territory_covers", "player", "x", "y"), &NativeSim::territory_covers);
	ClassDB::bind_method(D_METHOD("flagged_aura_circles", "player", "flag"), &NativeSim::flagged_aura_circles);
	ClassDB::bind_method(D_METHOD("free_cell_near_rect", "cx", "cy", "w", "h", "max_radius"), &NativeSim::free_cell_near_rect);
	ClassDB::bind_method(D_METHOD("income"), &NativeSim::income);
	ClassDB::bind_method(D_METHOD("blocked_bytes"), &NativeSim::blocked_bytes);
	ClassDB::bind_method(D_METHOD("grid_tiles_w"), &NativeSim::grid_tiles_w);
	ClassDB::bind_method(D_METHOD("grid_tiles_h"), &NativeSim::grid_tiles_h);

	ClassDB::bind_method(D_METHOD("fixed_from_int", "i"), &NativeSim::fixed_from_int);
	ClassDB::bind_method(D_METHOD("fixed_to_int", "a"), &NativeSim::fixed_to_int);
	ClassDB::bind_method(D_METHOD("fixed_mul", "a", "b"), &NativeSim::fixed_mul);
	ClassDB::bind_method(D_METHOD("fixed_div", "a", "b"), &NativeSim::fixed_div);
	ClassDB::bind_method(D_METHOD("fixed_floor", "a"), &NativeSim::fixed_floor);
	ClassDB::bind_method(D_METHOD("fixed_round", "a"), &NativeSim::fixed_round);
	ClassDB::bind_method(D_METHOD("fixed_sqrt", "a"), &NativeSim::fixed_sqrt);

	ClassDB::bind_method(D_METHOD("drng_stream", "seed", "n"), &NativeSim::drng_stream);
	ClassDB::bind_method(D_METHOD("drng_randi_range", "seed", "lo", "hi", "n"),
			&NativeSim::drng_randi_range);
	ClassDB::bind_method(D_METHOD("drng_rand_fixed", "seed", "n"), &NativeSim::drng_rand_fixed);

	ClassDB::bind_method(D_METHOD("proc_rolls", "seed", "base", "bonus", "n"),
			&NativeSim::proc_rolls);

	ClassDB::bind_method(D_METHOD("simhash_string", "s"), &NativeSim::simhash_string);

	ClassDB::bind_method(D_METHOD("grid_hash", "tiles_w", "tiles_h", "blocks"),
			&NativeSim::grid_hash);
	ClassDB::bind_method(D_METHOD("grid_nearest_free", "tiles_w", "tiles_h", "blocks", "cx", "cy"),
			&NativeSim::grid_nearest_free);
}

// --- boundary surface -------------------------------------------------------
void NativeSim::construct(int64_t seed, Object *catalog, Object *map) {
	_sim.construct(seed, catalog, map);
}

int64_t NativeSim::state_hash() const { return _sim.state_hash(); }
int64_t NativeSim::get_tick() const { return _sim.tick; }
void NativeSim::step() { _sim.step(); }

void NativeSim::schedule(int64_t player_id, int64_t kind, const PackedInt32Array &targets,
		const Dictionary &params, int64_t seq, int64_t at_tick) {
	mrts::Command c;
	c.player_id = player_id;
	c.kind = kind;
	c.targets.assign(targets.ptr(), targets.ptr() + targets.size());
	c.params = params;
	c.seq = seq;
	_sim.schedule(c, at_tick);
}

void NativeSim::load_triggers(Object *program) { _sim.load_triggers(program); }
Array NativeSim::trigger_presentation() { return _sim.triggers.drain_presentation(); }

Dictionary NativeSim::view_snapshot(int64_t viewer) const { return _sim.view_snapshot(viewer); }
PackedByteArray NativeSim::vision_of(int64_t player) const { return _sim.vision_bytes(player); }
Dictionary NativeSim::resources_of(int64_t player) const { return _sim.resources_of(player); }
Dictionary NativeSim::bandwidth_of(int64_t player) const { return _sim.bandwidth_of(player); }
Dictionary NativeSim::players_snapshot() const { return _sim.players_snapshot(); }
Dictionary NativeSim::match_result() const { return _sim.match_result(); }
bool NativeSim::is_entity_visible(int64_t player, int64_t entity_id) const {
	return _sim.is_entity_visible(player, entity_id);
}
bool NativeSim::is_tile_visible(int64_t player, int64_t tx, int64_t ty) const {
	return _sim.is_tile_visible(player, tx, ty);
}
bool NativeSim::is_cell_visible(int64_t player, int64_t cx, int64_t cy) const {
	return _sim.is_cell_visible(player, cx, cy);
}

PackedInt32Array NativeSim::buildable_structures(int64_t player) const { return _sim.buildable_structures(player); }
int64_t NativeSim::builder_for(int64_t player, int64_t type_key, int64_t cx, int64_t cy) const {
	return _sim.builder_for(player, type_key, cx, cy);
}
String NativeSim::build_block_reason(int64_t player, int64_t type_key) const {
	return _sim.build_block_reason(player, type_key);
}
PackedInt32Array NativeSim::trainable_units(int64_t player) const { return _sim.trainable_units(player); }
int64_t NativeSim::train_structure_for(int64_t player, int64_t type_key) const {
	return _sim.train_structure_for(player, type_key);
}
PackedInt32Array NativeSim::stronghold_ids(int64_t player) const { return _sim.stronghold_ids(player); }
PackedInt32Array NativeSim::depot_ids(int64_t player) const { return _sim.depot_ids(player); }
Dictionary NativeSim::depot_economy(int64_t depot_id) const { return _sim.depot_economy(depot_id); }
Array NativeSim::training_queues(int64_t player) const { return _sim.training_queues(player); }
Array NativeSim::vents() const { return _sim.vents(); }
int64_t NativeSim::vent_at(int64_t cx, int64_t cy, int64_t w, int64_t h) const { return _sim.vent_at(cx, cy, w, h); }
bool NativeSim::vent_taken(int64_t vent_id) const { return _sim.vent_taken(vent_id); }
bool NativeSim::territory_covers(int64_t player, int64_t x, int64_t y) const {
	return _sim.territory_covers(player, x, y);
}
Array NativeSim::flagged_aura_circles(int64_t player, const String &flag) const {
	return _sim.flagged_aura_circles(player, flag);
}
int64_t NativeSim::free_cell_near_rect(int64_t cx, int64_t cy, int64_t w, int64_t h, int64_t max_radius) const {
	return _sim.free_cell_near_rect(cx, cy, w, h, max_radius);
}
Dictionary NativeSim::income() const { return _sim.income(); }
PackedByteArray NativeSim::blocked_bytes() const { return _sim.blocked_bytes(); }
int64_t NativeSim::grid_tiles_w() const { return _sim.grid_tiles_w(); }
int64_t NativeSim::grid_tiles_h() const { return _sim.grid_tiles_h(); }

// --- Fixed ------------------------------------------------------------------
int64_t NativeSim::fixed_from_int(int64_t i) const { return Fixed::from_int(i); }
int64_t NativeSim::fixed_to_int(int64_t a) const { return Fixed::to_int(a); }
int64_t NativeSim::fixed_mul(int64_t a, int64_t b) const { return Fixed::mul(a, b); }
int64_t NativeSim::fixed_div(int64_t a, int64_t b) const { return Fixed::div(a, b); }
int64_t NativeSim::fixed_floor(int64_t a) const { return Fixed::floor(a); }
int64_t NativeSim::fixed_round(int64_t a) const { return Fixed::round(a); }
int64_t NativeSim::fixed_sqrt(int64_t a) const { return Fixed::sqrt(a); }

// --- DRng -------------------------------------------------------------------
PackedInt64Array NativeSim::drng_stream(int64_t seed, int64_t n) const {
	DRng rng(seed);
	PackedInt64Array out;
	for (int64_t i = 0; i < n; i++) {
		out.push_back(rng.next());
	}
	return out;
}

PackedInt64Array NativeSim::drng_randi_range(int64_t seed, int64_t lo, int64_t hi, int64_t n) const {
	DRng rng(seed);
	PackedInt64Array out;
	for (int64_t i = 0; i < n; i++) {
		out.push_back(rng.randi_range(lo, hi));
	}
	return out;
}

PackedInt64Array NativeSim::drng_rand_fixed(int64_t seed, int64_t n) const {
	DRng rng(seed);
	PackedInt64Array out;
	for (int64_t i = 0; i < n; i++) {
		out.push_back(rng.rand_fixed());
	}
	return out;
}

// --- ProcRng ----------------------------------------------------------------
PackedInt32Array NativeSim::proc_rolls(int64_t seed, int64_t base, int64_t bonus, int64_t n) const {
	DRng rng(seed);
	ProcStacks stacks;
	PackedInt32Array out;
	for (int64_t i = 0; i < n; i++) {
		out.push_back(ProcRng::roll(rng, stacks, "crit", base, bonus) ? 1 : 0);
	}
	return out;
}

// --- SimHash ----------------------------------------------------------------
int64_t NativeSim::simhash_string(const String &s) const {
	return SimHash::fnv_string(std::string(s.utf8().get_data()));
}

// --- SimGrid ----------------------------------------------------------------
static SimGrid build_grid(int64_t tiles_w, int64_t tiles_h, const PackedInt32Array &blocks) {
	SimGrid g(tiles_w, tiles_h);
	for (int64_t i = 0; i + 3 < blocks.size(); i += 4) {
		g.block_rect(blocks[i], blocks[i + 1], blocks[i + 2], blocks[i + 3]);
	}
	return g;
}

int64_t NativeSim::grid_hash(int64_t tiles_w, int64_t tiles_h, const PackedInt32Array &blocks) const {
	SimGrid g = build_grid(tiles_w, tiles_h, blocks);
	return g.hash_into(0);
}

int64_t NativeSim::grid_nearest_free(int64_t tiles_w, int64_t tiles_h,
		const PackedInt32Array &blocks, int64_t cx, int64_t cy) const {
	SimGrid g = build_grid(tiles_w, tiles_h, blocks);
	return g.nearest_free_cell(cx, cy);
}
