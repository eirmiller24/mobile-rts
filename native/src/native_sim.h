#pragma once
// NativeSim — the single GDExtension boundary class for the native sim
// (design_m5.md §2.3). GDScript crosses here O(1) times per tick: new(),
// schedule(), step(), state_hash(), plus batch read APIs for the view.
//
// During the port this class also exposes a set of substrate parity hooks
// (fixed_*/drng_*/proc_*/simhash_*/grid_*) used by tests/native_substrate_check
// to prove Fixed/DRng/ProcRng/SimHash/SimGrid are bit-exact against the frozen
// GDScript reference before the heavier systems land. They are pure functions
// of their arguments (no sim state) and stay cheap; the full sim surface grows
// alongside the systems port (design_m5.md §8).

#include <memory>

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>
#include <godot_cpp/variant/packed_int64_array.hpp>
#include <godot_cpp/variant/string.hpp>

#include "sim/sim.h"

using namespace godot;

class NativeSim : public RefCounted {
	GDCLASS(NativeSim, RefCounted)

protected:
	static void _bind_methods();

public:
	NativeSim() = default;
	~NativeSim() = default;

	// --- boundary surface (design_m5.md §2.3) ---
	// construct() replaces the GDScript `Sim.new(seed, catalog, map)`: the
	// GDExtension constructor can't take args, so the view/tests do
	// `var s = NativeSim.new(); s.construct(seed, catalog, map)`.
	void construct(int64_t seed, Object *catalog, Object *map);
	int64_t state_hash() const;
	int64_t get_tick() const;
	void step();
	// Mirror of Sim.schedule: build a native Command from the wire fields and
	// queue it. targets is sorted-ascending entity ids; params is the kind's
	// payload Dictionary; at_tick < 0 means tick + COMMAND_DELAY.
	void schedule(int64_t player_id, int64_t kind, const PackedInt32Array &targets,
			const Dictionary &params, int64_t seq, int64_t at_tick);

	// --- batch view read API ---
	Dictionary view_snapshot(int64_t viewer) const;
	PackedByteArray vision_of(int64_t player) const;
	Dictionary resources_of(int64_t player) const;
	Dictionary bandwidth_of(int64_t player) const;
	Dictionary players_snapshot() const;
	Dictionary match_result() const;
	bool is_entity_visible(int64_t player, int64_t entity_id) const;
	bool is_tile_visible(int64_t player, int64_t tx, int64_t ty) const;
	bool is_cell_visible(int64_t player, int64_t cx, int64_t cy) const;

	// --- per-interaction read queries ---
	PackedInt32Array buildable_structures(int64_t player) const;
	int64_t builder_for(int64_t player, int64_t type_key, int64_t cx, int64_t cy) const;
	String build_block_reason(int64_t player, int64_t type_key) const;
	PackedInt32Array trainable_units(int64_t player) const;
	int64_t train_structure_for(int64_t player, int64_t type_key) const;
	PackedInt32Array stronghold_ids(int64_t player) const;
	PackedInt32Array depot_ids(int64_t player) const;
	Dictionary depot_economy(int64_t depot_id) const;
	Array training_queues(int64_t player) const;
	Array vents() const;
	int64_t vent_at(int64_t cx, int64_t cy, int64_t w, int64_t h) const;
	bool vent_taken(int64_t vent_id) const;
	bool territory_covers(int64_t player, int64_t x, int64_t y) const;
	Array flagged_aura_circles(int64_t player, const String &flag) const;
	int64_t free_cell_near_rect(int64_t cx, int64_t cy, int64_t w, int64_t h, int64_t max_radius) const;
	Dictionary income() const;
	PackedByteArray blocked_bytes() const;
	int64_t grid_tiles_w() const;
	int64_t grid_tiles_h() const;

	// --- substrate parity hooks (Fixed) ---
	int64_t fixed_from_int(int64_t i) const;
	int64_t fixed_to_int(int64_t a) const;
	int64_t fixed_mul(int64_t a, int64_t b) const;
	int64_t fixed_div(int64_t a, int64_t b) const;
	int64_t fixed_floor(int64_t a) const;
	int64_t fixed_round(int64_t a) const;
	int64_t fixed_sqrt(int64_t a) const;

	// --- substrate parity hooks (DRng) ---
	PackedInt64Array drng_stream(int64_t seed, int64_t n) const;
	PackedInt64Array drng_randi_range(int64_t seed, int64_t lo, int64_t hi, int64_t n) const;
	PackedInt64Array drng_rand_fixed(int64_t seed, int64_t n) const;

	// --- substrate parity hooks (ProcRng) ---
	// Returns the per-roll outcomes (0/1) for n consecutive rolls of one proc.
	PackedInt32Array proc_rolls(int64_t seed, int64_t base, int64_t bonus, int64_t n) const;

	// --- substrate parity hooks (SimHash) ---
	int64_t simhash_string(const String &s) const;

	// --- substrate parity hooks (SimGrid) ---
	// blocks is a flat [cx, cy, w, h, ...] list of rects to block in order.
	int64_t grid_hash(int64_t tiles_w, int64_t tiles_h, const PackedInt32Array &blocks) const;
	// Returns nearest_free_cell after applying the blocks, for (cx, cy).
	int64_t grid_nearest_free(int64_t tiles_w, int64_t tiles_h,
			const PackedInt32Array &blocks, int64_t cx, int64_t cy) const;

private:
	mrts::Sim _sim;
};
