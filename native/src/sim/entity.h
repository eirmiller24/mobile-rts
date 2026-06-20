#pragma once
// One sim entity. Bit-exact port of src/sim/sim_entity.gd. Plain data advanced
// by the Sim systems. Every field that exists in the GDScript SimEntity is
// mirrored here, and hash_into() folds them in the identical order so the
// per-entity contribution to state_hash() matches byte for byte.
//
// Container choices preserve GDScript semantics:
//  - procs           : std::map<std::string,int64> (sorted, like sorted keys)
//  - ability_cooldowns: std::map<int64,int64>      (sorted keys)
//  - orders          : godot::Array of Dictionary  (1:1 with the GDScript
//                       order queue; hash reads kind/x/y)
//  - train_queue     : std::vector<TrainEntry>     (type/left/replace_depot)
//  - linked_vents/path: std::vector<int32_t>

#include <cstdint>
#include <map>
#include <string>
#include <vector>

#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/dictionary.hpp>

#include "sim/fixed.h"
#include "sim/proc_rng.h"
#include "sim/sim_hash.h"

namespace mrts {

struct TrainEntry {
	int64_t type = 0;
	int64_t left = 0;
	int64_t replace_depot = 0; // 0 = none
};

struct Entity {
	enum Kind { UNIT = 0, STRUCTURE = 1, RESOURCE = 2 };
	enum BuildState { CAPSULE = 0, GROWING = 1, COMPLETE = 2 };
	enum HarvestState { IDLE = 0, TO_SOURCE = 1, HARVESTING = 2, TO_DEPOT = 3, DEPOSITING = 4 };
	enum WorkState { WS_ALLOY = 0, WS_ALLOY_BUILD = 1, WS_FLUX = 2, WS_FLUX_BUILD = 3, WS_MANUAL = 4 };

	int64_t id = 0;
	int64_t player = 0;
	int64_t kind = UNIT;
	int64_t type_key = -1;

	int64_t x = 0;
	int64_t y = 0;
	int64_t radius = 0;
	int64_t step = 0;

	int64_t hp = 0;
	int64_t max_hp = 0;
	bool targetable = true;
	int64_t damage = 0;
	int64_t attack_range = 0;
	int64_t acquire_range = 0;
	int64_t cooldown_ticks = 0;
	int64_t cooldown = 0;
	int64_t crit_base = 0;
	int64_t crit_bonus = 0;
	ProcStacks procs;
	int64_t sight = 0;
	bool hits_air = false;
	int64_t attack_class = -1;
	int64_t armor_class = -1;
	int64_t damage_taken = Fixed::ONE;

	int64_t amount = 0;
	int64_t resource_kind = -1;

	int64_t target_id = 0;

	godot::Array orders; // Array[Dictionary]: {kind, x, y, small}
	int64_t goal_key = -1;
	int64_t done_goal_key = -1;
	std::vector<int32_t> path;
	int64_t path_i = 0;
	int64_t goal_d2_best = 0;
	int64_t stall = 0;

	int64_t foot_x = 0;
	int64_t foot_y = 0;
	int64_t foot_w = 0;
	int64_t foot_h = 0;
	bool blocks = false;

	int64_t build_state = COMPLETE;
	int64_t build_ticks_left = 0;
	int64_t assist_bonus = 0;
	int64_t heal_acc = 0;
	int64_t vent_id = 0;
	int64_t nano_alloc[3] = {0, 0, 0};

	std::vector<TrainEntry> train_queue;
	int64_t rally_x = 0;
	int64_t rally_y = 0;

	bool morphed = false;
	int64_t morph_ticks_left = 0;
	int64_t underground_ticks_left = 0;
	int64_t surface_x = 0;
	int64_t surface_y = 0;
	std::map<int64_t, int64_t> ability_cooldowns;

	int64_t harvest_state = IDLE;
	int64_t carry = 0;
	int64_t carry_kind = -1;
	int64_t assigned_source = 0;
	int64_t work_state = WS_ALLOY;
	int64_t home_depot = 0;

	int64_t worker_target = 0;
	int64_t eco_alloy = 0;
	int64_t eco_alloy_build = 0;
	int64_t eco_flux_build = 0;

	int64_t build_target = 0;
	int64_t wall_target_cell = -1;
	bool needs_builder = false;
	std::vector<int32_t> linked_vents;

	int64_t stance = 0;
	int64_t tactic_flags = 0;
	int64_t anchor_x = 0;
	int64_t anchor_y = 0;
	bool anchor_set = false;

	// --- helper methods (mirror sim_entity.gd) ---
	inline int64_t mine_role() const {
		if (work_state == WS_ALLOY || work_state == WS_ALLOY_BUILD) return 1;
		if (work_state == WS_FLUX || work_state == WS_FLUX_BUILD) return 2;
		return 0;
	}
	inline bool build_draftable() const {
		return work_state == WS_ALLOY_BUILD || work_state == WS_FLUX_BUILD;
	}
	inline bool is_manual_worker() const { return work_state == WS_MANUAL; }
	inline bool is_underground() const { return underground_ticks_left > 0; }
	inline bool is_unit() const { return kind == UNIT; }
	inline bool is_resource() const { return kind == RESOURCE; }
	inline bool is_aerial() const {
		return kind == STRUCTURE && build_state == CAPSULE;
	}

	int64_t hash_into(int64_t h) const {
		const int64_t flat[] = {
			id, player, kind, type_key, x, y, radius, step, hp, max_hp,
			(int64_t)targetable, damage, attack_range, acquire_range,
			cooldown_ticks, cooldown, crit_base, crit_bonus, target_id,
			sight, (int64_t)hits_air, attack_class, armor_class, damage_taken,
			amount, resource_kind,
			goal_key, done_goal_key, path_i, goal_d2_best, stall,
			foot_x, foot_y, foot_w, foot_h, (int64_t)blocks,
			build_state, build_ticks_left, assist_bonus, heal_acc, vent_id,
			nano_alloc[0], nano_alloc[1], nano_alloc[2],
			rally_x, rally_y, (int64_t)morphed, morph_ticks_left,
			underground_ticks_left, surface_x, surface_y,
			harvest_state, carry, carry_kind, assigned_source, work_state,
			home_depot, worker_target, eco_alloy, eco_alloy_build, eco_flux_build,
			build_target, wall_target_cell, (int64_t)needs_builder,
			stance, tactic_flags, anchor_x, anchor_y, (int64_t)anchor_set
		};
		for (int64_t v : flat) {
			h = SimHash::mix(h, v);
		}
		for (int32_t vent : linked_vents) {
			h = SimHash::mix(h, vent);
		}
		for (const TrainEntry &q : train_queue) {
			h = SimHash::mix(h, q.type);
			h = SimHash::mix(h, q.left);
			h = SimHash::mix(h, q.replace_depot);
		}
		// ability_cooldowns: ascending key (std::map is already sorted).
		for (const auto &kv : ability_cooldowns) {
			h = SimHash::mix(h, kv.first);
			h = SimHash::mix(h, kv.second);
		}
		// procs: ascending key, fold fnv_string(key) then stack count.
		for (const auto &kv : procs) {
			h = SimHash::mix(h, SimHash::fnv_string(kv.first));
			h = SimHash::mix(h, kv.second);
		}
		// orders: fold kind, x, y of each.
		for (int i = 0; i < orders.size(); i++) {
			godot::Dictionary o = orders[i];
			h = SimHash::mix(h, (int64_t)o["kind"]);
			h = SimHash::mix(h, (int64_t)o["x"]);
			h = SimHash::mix(h, (int64_t)o["y"]);
		}
		for (int32_t c : path) {
			h = SimHash::mix(h, c);
		}
		return h;
	}
};

} // namespace mrts
