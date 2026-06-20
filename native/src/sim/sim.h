#pragma once
// The deterministic game simulation, C++ side (design_m5.md §2). Port of
// src/sim/sim.gd — headless, tick-driven, fixed-point. The GDScript Sim is the
// frozen parity oracle (§2.4); this is the sole forward implementation.
//
// Constitution (design.md):
//  - No floats, no engine physics/nodes/time, randomness only via `rng`.
//  - All entity iteration is ascending-id; IdVec gives that, and matches the
//    GDScript Dictionary insertion order (inserts are id-ordered). Systems that
//    spawn/erase mid-pass iterate a _sorted_ids() snapshot, exactly like the
//    GDScript, and re-fetch Entity* after a spawn (a vector put can realloc).
//  - Inputs are the construction seed and scheduled commands.

#include <array>
#include <cstdint>
#include <map>
#include <utility>
#include <vector>

#include <godot_cpp/classes/object.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>
#include <godot_cpp/variant/packed_int64_array.hpp>
#include <godot_cpp/variant/string.hpp>

#include "sim/catalog_view.h"
#include "sim/command.h"
#include "sim/drng.h"
#include "sim/entity.h"
#include "sim/id_vec.h"
#include "sim/pathing.h"
#include "sim/player.h"
#include "sim/region.h"
#include "sim/sim_grid.h"
#include "sim/trigger_vm.h"

namespace mrts {

// A 2D fixed-point point/vector (replaces the view's Vector2i in sim math).
struct V2 {
	int64_t x = 0;
	int64_t y = 0;
	bool operator==(const V2 &o) const { return x == o.x && y == o.y; }
};

class Sim {
public:
	static constexpr int TICK_RATE = 20;
	static constexpr int COMMAND_DELAY = 3;
	static constexpr int VISION_PERIOD = 4;
	static constexpr int SMALL_GROUP = 3;
	static constexpr bool USE_FLOW_FIELDS = false;
	static constexpr int64_t ARRIVE_DIST = SimGrid::CELL;
	static constexpr int64_t WAYPOINT_REACH = SimGrid::CELL;
	static constexpr int BUCKET_SHIFT = Fixed::SHIFT + 1;
	static constexpr int64_t SLOT_SWITCH_DIST = Fixed::ONE * 3;
	static constexpr int SLOT_MAX = 24;
	static constexpr int STALL_TICKS = 20;
	static constexpr int STALL_GIVE_UP_TICKS = 60;
	static constexpr int TRAIN_QUEUE_MAX = 5;
	static constexpr int64_t HARVEST_REACH = SimGrid::CELL * 2;
	static constexpr int64_t AUTO_MINE_RADIUS = SimGrid::CELL * 24;
	// GIVE_UP waypoint sentinel (real positions are clamped > 0).
	static constexpr V2 give_up() { return V2{-1, -1}; }

	int64_t tick = 0;
	DRng rng;
	SimGrid grid;
	CatalogView catalog;
	IdVec<Player> players;
	IdVec<Entity> entities;
	// Named map areas (design_m5.md §3.6), ascending id. Mutable by triggers
	// (move_region) so hashed; loaded from the map at construction.
	std::vector<Region> regions;
	Region *region_by_id(int64_t id);
	const Region *region_by_id(int64_t id) const;

	void construct(int64_t seed, godot::Object *catalog_obj, godot::Object *map_obj);
	int64_t state_hash() const;
	void step();
	void schedule(const Command &cmd, int64_t at_tick = -1);
	// Apply a command immediately (the trigger VM's order bridge, design_m5.md
	// §3.5 — a trigger-issued SimCommand runs the same validation as a player's).
	void apply_command(const Command &cmd) { _execute(cmd); }

	// --- triggers (design_m5.md §3) ---
	// The VM lives inside the wall as a sim subsystem; its state is hashed.
	TriggerVM triggers;
	// Compile-time-produced program, loaded after construct(), before stepping.
	void load_triggers(godot::Object *program);

	// scenario setup / spawning
	int64_t spawn_unit(int64_t player, int64_t x, int64_t y, int64_t type_key);
	int64_t spawn_structure(int64_t player, int64_t cx, int64_t cy, int64_t type_key, bool completed);
	int64_t spawn_resource(int64_t cx, int64_t cy, int64_t type_key);

	// vision queries (also used by the view)
	bool is_tile_visible(int64_t player, int64_t tx, int64_t ty) const;
	bool is_cell_visible(int64_t player, int64_t cx, int64_t cy) const;
	const std::vector<uint8_t> &vision_of(int64_t player) const;
	bool is_entity_visible(int64_t player, int64_t entity_id) const;

	// match result
	bool match_over() const;
	int64_t match_winner() const;

	// --- batch view read API (design_m5.md §2.3) ---
	// One crossing per tick: parallel packed arrays of every live entity (ascending
	// id) carrying the fields the view renders, with per-entity render visibility
	// for `viewer` pre-baked into `flags`. See sim_view.cpp for the field layout.
	godot::Dictionary view_snapshot(int64_t viewer) const;
	godot::PackedByteArray vision_bytes(int64_t player) const;
	godot::Dictionary resources_of(int64_t player) const;
	godot::Dictionary bandwidth_of(int64_t player) const;
	godot::Dictionary players_snapshot() const;
	godot::Dictionary match_result() const;

	// --- per-interaction read queries (console / placement / AI) ---
	godot::PackedInt32Array buildable_structures(int64_t player) const;
	int64_t builder_for(int64_t player, int64_t type_key, int64_t cx, int64_t cy) const;
	godot::String build_block_reason(int64_t player, int64_t type_key) const;
	godot::PackedInt32Array trainable_units(int64_t player) const;
	int64_t train_structure_for(int64_t player, int64_t type_key) const;
	godot::PackedInt32Array stronghold_ids(int64_t player) const;
	godot::PackedInt32Array depot_ids(int64_t player) const;
	godot::Dictionary depot_economy(int64_t depot_id) const;
	godot::Array training_queues(int64_t player) const;
	godot::Array vents() const;
	int64_t vent_at(int64_t cx, int64_t cy, int64_t w, int64_t h) const;
	bool vent_taken(int64_t vent_id) const;
	bool territory_covers(int64_t player, int64_t x, int64_t y) const;
	godot::Array flagged_aura_circles(int64_t player, const godot::String &flag) const;
	int64_t free_cell_near_rect(int64_t cx, int64_t cy, int64_t w, int64_t h, int64_t max_radius) const;
	godot::Dictionary income() const;
	// grid mirror for the view's GDScript SimGrid (synced each tick).
	godot::PackedByteArray blocked_bytes() const;
	int64_t grid_tiles_w() const;
	int64_t grid_tiles_h() const;

private:
	int64_t _construction_armor = -1;
	int64_t _data_hash = 0;
	int64_t _next_entity_id = 1;

	std::map<int64_t, std::vector<Command>> _command_queue;

	// Derived, never hashed.
	std::map<int64_t, std::vector<uint8_t>> _vision;
	std::vector<uint8_t> _occluders;
	bool _has_occluders = false;
	// Spatial buckets, rebuilt each movement/combat pass.
	std::map<std::pair<int64_t, int64_t>, std::vector<int32_t>> _buckets;
	// Aura source index: player -> ability type_key -> list of (owner_id,x,y,radius).
	std::map<int64_t, std::map<int64_t, std::vector<std::array<int64_t, 4>>>> _aura_sources;
	// Per-stronghold income for the Economy tab (derived, never hashed):
	// sh_id -> [alloy, flux, assist_used, idle_assist, idle].
	std::map<int64_t, std::array<int64_t, 5>> _income;

	static const std::vector<uint8_t> _empty_vision;

	// snapshot of present ids, ascending (matches GDScript _sorted_ids()).
	std::vector<int64_t> _sorted_ids() const;
	Entity *E(int64_t id) { return entities.find(id); }

	// --- construction-path (sim_construct.cpp) ---
	Entity &_place_footprint(int64_t player, int64_t cx, int64_t cy, int64_t type_key,
			const godot::Dictionary &s);
	Entity *_spawn_structure_entity(int64_t player, int64_t cx, int64_t cy, int64_t type_key,
			bool completed, int64_t vent_id);
	void _copy_combat_stats(Entity &e, const godot::Dictionary &s);
	void _on_structure_complete(Entity &e);
	bool _is_worker(const Entity &e) const;
	bool _is_depot(const Entity &e) const;
	bool _functional(const Entity *e) const;
	godot::PackedInt32Array _abilities_of(const Entity &e) const;
	int64_t _nearest_depot(const Entity &w) const;
	int64_t _nearest_depot_pos(int64_t pid, int64_t x, int64_t y) const;
	void _reseed_depot_target(Entity &depot);
	bool _circle_covers(int64_t cx, int64_t cy, int64_t r, int64_t x, int64_t y) const;
	bool _within_dist(int64_t ax, int64_t ay, int64_t bx, int64_t by, int64_t r) const;
	void _recompute_vision();
	void _rebuild_occluders();
	void _stamp_sight(std::vector<uint8_t> &vis, const Entity &e);
	bool _los_unoccluded(int64_t x0, int64_t y0, int64_t x1, int64_t y1) const;
	void _stamp_entity_tiles(std::vector<uint8_t> &vis, const Entity &e) const;
	bool _is_entity_visible(int64_t player, const Entity &e) const;

	// --- auras (sim_structures.cpp) ---
	void _rebuild_aura_index();
	bool _in_flagged_aura(int64_t player, const char *flag, int64_t x, int64_t y) const;
	bool _in_aura(int64_t player, int64_t ability_key, int64_t x, int64_t y) const;
	int64_t _eff_damage_taken(const Entity &e) const;
	int64_t _eff_hp_regen(const Entity &e) const;
	void _modifier_values(const Entity &e, const char *key, std::vector<int64_t> &out) const;
	int64_t _territory_radius(const Entity &e) const;

	// --- commands (sim_commands.cpp) ---
	void _execute_scheduled_commands();
	void _execute(const Command &cmd);
	void _execute_build(const Command &cmd);
	bool _build_ability_for(const Entity &builder, int64_t type) const;
	int64_t _build_mechanic_for(const Entity &builder, int64_t type) const;
	void _execute_worker_build(int64_t player_id, Entity &builder, int64_t type,
			int64_t cx, int64_t cy, int64_t w, int64_t h);
	int64_t _vent_at(int64_t cx, int64_t cy, int64_t w, int64_t h) const;
	int64_t _siphon_on(int64_t vent_id) const;
	void _spawn_capsule(int64_t player, int64_t cx, int64_t cy, int64_t type_key, int64_t vent_id);
	void _execute_allocate(const Command &cmd);
	std::vector<int64_t> _own_unit_ids(const Command &cmd) const;
	void _order_move(const Command &cmd);
	std::vector<int64_t> _surround_slots(int64_t gcx, int64_t gcy, const std::vector<int64_t> &unit_ids);
	int64_t _cell_dist2(int64_t ax, int64_t ay, int64_t bx, int64_t by) const;
	int64_t _min_dist2_to(int64_t cx, int64_t cy, const std::vector<std::pair<int64_t, int64_t>> &picked) const;
	void _start_order(Entity &e);
	int64_t _cell_index_of(const Entity &e) const;
	void _execute_train(const Command &cmd);
	void _execute_cancel(const Command &cmd);
	void _execute_set_rally(const Command &cmd);
	void _execute_ability(const Command &cmd);
	void _execute_toggle_group(int64_t ability, const godot::Dictionary &ab, const std::vector<int64_t> &unit_ids);
	void _execute_set_tactic(const Command &cmd);
	void _execute_patrol(const Command &cmd);
	void _execute_mine(const Command &cmd);
	void _execute_set_economy(const Command &cmd);
	void _execute_repair(const Command &cmd);
	void _execute_build_wall(const Command &cmd);
	void _move_to_entity(Entity &w, const Entity &t);
	void _move_to_cell(Entity &w, int64_t cell);

	// --- movement (sim_movement.cpp) ---
	void _movement_system();
	V2 _waypoint(Entity &e, godot::Dictionary &o);
	V2 _steer_around(const Entity &e, int64_t dx, int64_t dy, int64_t d);
	bool _arrived_neighbor(const Entity &e, const Entity &n) const;
	void _complete_order(Entity &e);
	void _drop_order(Entity &e);
	void _push_out_of_blocked(Entity &e);
	void _rebuild_buckets(const std::vector<int64_t> &ids);
	void _bucket_insert(int64_t bx, int64_t by, int64_t id);
	std::vector<int64_t> _bucket_neighbors(const Entity &e, int64_t radius_buckets, int64_t above) const;
	int64_t _length(int64_t dx, int64_t dy) const;
	int64_t _isqrt(int64_t n) const;

	// --- combat / stance / status (sim_combat.cpp) ---
	void _combat_system();
	int64_t _eff_armor_class(const Entity &t) const;
	bool _engaged(const Entity &e) const;
	bool _can_target(const Entity &e, const Entity &t) const;
	Entity *_acquire(Entity &e);
	Entity *_focus_target(Entity &e);
	bool _in_range(const Entity &e, const Entity &t, int64_t r, bool edge_to_edge) const;
	void _reap();
	void _stance_system();
	void _stance_defensive(Entity &e, Entity *t, bool has_target);
	void _step_toward(Entity &e, int64_t tx, int64_t ty);
	void _status_system();
	void _apply_morph_stats(Entity &e);
	void _surface(Entity &e);

	// --- economy (sim_economy.cpp) ---
	void _economy_system();
	int64_t _mine(Entity &sh, Player &player, int64_t r, int64_t res_kind, int64_t rate, int64_t nanos);
	int64_t _assist(Entity &sh, int64_t r, int64_t nanos);
	void _worker_economy_system();
	void _auto_replace_depot(Entity &depot);
	int64_t _queued_worker_home(const Entity &structure, const TrainEntry &entry) const;
	void _apply_worker_split_to_depot(Entity &depot);
	int64_t _gap_fill_state(const Entity &depot) const;
	void _grow_depot_target(Entity &depot);
	int64_t _worker_type_for(int64_t pid) const;
	void _queue_replacement_at(Entity &depot);
	void _harvest_tick(Entity &w, std::map<int64_t, int64_t> &budget);
	bool _valid_source(const Entity *src) const;
	int64_t _role_of_source(const Entity *src) const;
	bool _source_matches_role(const Entity *src, int64_t role) const;
	int64_t _pick_source(const Entity &w, int64_t role) const;
	bool _discovered_resource(int64_t pid, int64_t res_id) const;
	bool _within_home_radius(const Entity &src, const Entity &w) const;
	void _ensure_home_depot(Entity &w);
	int64_t _nearest_refinery(const Entity &w) const;
	int64_t _node_assignees(int64_t node_id, int64_t pid) const;
	int64_t _node_saturation(const Entity &w, const Entity &node) const;
	int64_t _entity_dist2(const Entity &a, const Entity &b) const;
	bool _within_reach(const Entity &w, const Entity &t) const;
	int64_t _carry_cap_for(const Entity &w, const Entity &src) const;
	bool _is_raw_vent(const Entity &src) const;
	int64_t _harvest_rate_for(const Entity &w, const Entity &src) const;
	void _harvest_draw(Entity &w, Entity &src, std::map<int64_t, int64_t> &budget);
	int64_t _draw_node(Entity &node, int64_t demand, std::map<int64_t, int64_t> &budget);
	void _worker_build_system();
	bool _valid_build_target(const Entity *t, const Entity &w) const;
	void _apply_builder(const Entity &w, Entity &t);
	int64_t _build_rate_of(const Entity &w) const;
	int64_t _repair_rate_of(const Entity &w) const;
	void _wall_system();
	Entity *_nearest_available_builder(int64_t pid, int64_t cell);
	bool _within_cell_reach(const Entity &w, int64_t cell) const;

	// --- production / structures / elimination (sim_structures.cpp) ---
	void _production_system();
	int64_t _free_cell_near_rect(int64_t cx, int64_t cy, int64_t w, int64_t h, int64_t max_radius = 12) const;
	void _structures_system();
	void _capsule_tick(Entity &e);
	int64_t _siphon_on_excluding(int64_t vent_id, int64_t self_id) const;
	bool _units_on_footprint(const Entity &e) const;
	void _grow_tick(Entity &e);
	int64_t _ramp_hp(int64_t max_hp, int64_t total, int64_t left) const;
	void _regen_tick(Entity &e);
	void _check_elimination();

	// queries used by command handlers
	void _bandwidth_of(int64_t player, int64_t &used, int64_t &provided) const;
	godot::PackedInt32Array _trainable_units(int64_t player) const;
	int64_t _train_structure_for(int64_t player, int64_t type_key) const;
};

} // namespace mrts
