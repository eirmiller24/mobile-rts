#pragma once
// The trigger VM — an expressive AST-walker living inside the sim wall
// (design_m5.md §3.2). It reads the flat interned program the GDScript compiler
// emits (docs/trigger_ir.md), runs event handlers as suspendable activations,
// and mutates the match only through the Sim it points at. All its state is
// hashed sim state (§3.6); presentation effects go to an unhashed view queue
// (§3.4).
//
// Execution model (§3.7): one iterative statement driver (run_frame) walks an
// explicit continuation stack so `wait` can suspend mid-control-flow and resume
// on a future tick. Expressions and user-function calls evaluate recursively
// (bounded by a call-depth cap); functions never `wait` (compiler-enforced), so
// no host-stack frame is ever live across a suspension. An op budget bounds work
// per tick — a runaway script is killed, never hangs.

#include <cstdint>
#include <map>
#include <memory>
#include <vector>

#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/string.hpp>

#include "sim/sim_hash.h"
#include "sim/trigger_ir.h"

namespace godot {
class Object;
}

namespace mrts {

class Sim;

// The loaded program: flat int tables marshalled once from the GDScript
// TriggerProgram object. Plain data the VM owns (no pointer graph).
struct TProgram {
	std::vector<int32_t> nodes;     // stride NODE_STRIDE
	std::vector<int32_t> lists;
	std::vector<int64_t> ints;
	std::vector<godot::String> strings;
	std::vector<int32_t> globals;   // stride GLOBAL_STRIDE: [type, init_node]
	std::vector<int32_t> functions; // stride FUNC_STRIDE
	std::vector<int32_t> events;    // stride EVENT_STRIDE
	int64_t hash_value = 0;

	void load(godot::Object *prog); // prog may be null -> empty program

	inline int n_globals() const { return (int)globals.size() / tir::GLOBAL_STRIDE; }
	inline int n_functions() const { return (int)functions.size() / tir::FUNC_STRIDE; }
	inline int n_events() const { return (int)events.size() / tir::EVENT_STRIDE; }

	// node field accessors (n is a node index)
	inline int op(int n) const { return nodes[n * tir::NODE_STRIDE + 0]; }
	inline int t(int n) const { return nodes[n * tir::NODE_STRIDE + 1]; }
	inline int a(int n) const { return nodes[n * tir::NODE_STRIDE + 2]; }
	inline int b(int n) const { return nodes[n * tir::NODE_STRIDE + 3]; }
	inline int c(int n) const { return nodes[n * tir::NODE_STRIDE + 4]; }
	inline int d(int n) const { return nodes[n * tir::NODE_STRIDE + 5]; }
};

// A typed runtime value (§3.6). Numbers are int/fixed (no float). Refs are ids.
// point packs (x,y) into (a,b); filter packs (kind,arg); group holds an id list.
struct Value {
	int type = tir::T_VOID;
	int64_t a = 0;
	int64_t b = 0;
	std::shared_ptr<std::vector<int64_t>> grp;

	static Value int_v(int64_t v) { return {tir::T_INT, v, 0, nullptr}; }
	static Value fixed_v(int64_t v) { return {tir::T_FIXED, v, 0, nullptr}; }
	static Value bool_v(bool v) { return {tir::T_BOOL, v ? 1 : 0, 0, nullptr}; }
	static Value point_v(int64_t x, int64_t y) { return {tir::T_POINT, x, y, nullptr}; }
	static Value ref_v(int type, int64_t id) { return {type, id, 0, nullptr}; }

	int64_t hash_into(int64_t h) const {
		h = SimHash::mix(h, type);
		h = SimHash::mix(h, a);
		h = SimHash::mix(h, b);
		if (grp) {
			h = SimHash::mix(h, (int64_t)grp->size());
			for (int64_t id : *grp) {
				h = SimHash::mix(h, id);
			}
		}
		return h;
	}
};

// A tick-counted timer (never wall-clock). Hashed.
struct VmTimer {
	int64_t id = 0;
	int64_t remaining = 0;
	int64_t period = 0;
	bool repeating = false;
	bool active = true;
};

// The event subject a handler's context queries read (triggering_unit, ...).
struct EventCtx {
	int64_t unit = 0;    // triggering / entering / dying / created / completed
	int64_t unit2 = 0;   // killer / damage source
	int64_t player = 0;
	int64_t region = 0;
	int64_t timer = 0;
};

// One in-progress statement within a frame's explicit continuation stack.
struct Cont {
	int node = 0;
	int pc = 0;
	int64_t s0 = 0; // loop scratch: index / counter
	int64_t s1 = 0; // loop scratch: end bound
	int64_t s2 = 0; // loop scratch: step
	std::shared_ptr<std::vector<int64_t>> grp; // for-each snapshot
};

// An activation: a handler (or resumed wait) running its body. Suspendable.
struct Frame {
	int64_t id = 0;          // suspension id (ordering + hashing)
	std::vector<Value> locals;
	std::vector<Cont> conts;
	EventCtx ctx;
	Value ret;
	bool returned = false;
	int64_t resume_tick = 0;

	int64_t hash_into(int64_t h) const {
		h = SimHash::mix(h, id);
		h = SimHash::mix(h, resume_tick);
		h = SimHash::mix(h, ctx.unit);
		h = SimHash::mix(h, ctx.unit2);
		h = SimHash::mix(h, ctx.player);
		h = SimHash::mix(h, ctx.region);
		h = SimHash::mix(h, ctx.timer);
		for (const Value &v : locals) {
			h = v.hash_into(h);
		}
		for (const Cont &k : conts) {
			h = SimHash::mix(h, k.node);
			h = SimHash::mix(h, k.pc);
			h = SimHash::mix(h, k.s0);
			h = SimHash::mix(h, k.s1);
			h = SimHash::mix(h, k.s2);
			if (k.grp) {
				h = SimHash::mix(h, (int64_t)k.grp->size());
				for (int64_t gid : *k.grp) {
					h = SimHash::mix(h, gid);
				}
			}
		}
		return h;
	}
};

class TriggerVM {
public:
	// Tuning (design_m5.md §3.7 / §9 Q4). Placeholder numbers, ample for the
	// target maps; a runaway script trips them and is killed with a diagnostic.
	static constexpr int64_t OP_BUDGET = 2'000'000;
	static constexpr int CALL_DEPTH_CAP = 128;

	// Marshal the program and initialise globals. `program` may be null (a map
	// with no triggers.lua) -> an inert VM.
	void load(Sim *sim, godot::Object *program);

	// The per-tick trigger phase (design_m5.md §3.7). The first call also runs
	// map_init then match_start handlers; later calls resume due waits, advance
	// timers, fire every() handlers, and detect region enter/leave.
	void tick_phase();

	// Sim-system event hooks (the per-tick event list, §3.7). _reap fires deaths
	// in-place (entities still present); _on_structure_complete defers a
	// completion to the next phase. Both no-op before match_start / when inert.
	void fire_deaths(const std::vector<int64_t> &ids);
	void note_structure_complete(int64_t id);

	bool active() const { return _active; }

	int64_t hash_into(int64_t h) const;

	// Drain the per-tick presentation queue for the view (unhashed, §3.4).
	godot::Array drain_presentation();

private:
	Sim *_sim = nullptr;
	TProgram _prog;
	bool _loaded = false; // a program was loaded -> trigger state joins the hash
	bool _active = false;
	bool _started = false;

	std::vector<Value> _glob;
	std::vector<VmTimer> _timers;
	int64_t _next_timer_id = 1;
	int64_t _next_frame_id = 1;
	std::vector<Frame> _suspended; // ascending resume order by frame id

	// Region membership for enter/leave detection: region id -> ascending member
	// unit ids (hashed). Seeded at match_start so units already inside don't fire
	// a spurious enter.
	std::map<int64_t, std::vector<int64_t>> _region_members;
	bool _region_seeded = false;
	bool _has_region_events = false;
	// structure_completes ids deferred from _on_structure_complete (drained next
	// phase; structures persist so this is safe). Hashed while pending.
	std::vector<int64_t> _completed_pending;

	int64_t _ops = 0;
	int _depth = 0;

	// Presentation records: {0=message who text_idx} / {1=ping who x y}. Cleared
	// each drain. Never hashed.
	struct PresRec { int kind; int64_t who; int64_t x; int64_t y; int str_idx; };
	std::vector<PresRec> _pres;

	// --- execution ---
	void run_event(int ev_index, const EventCtx &ctx);
	void fire_kind(int kind, const EventCtx &ctx); // all handlers of one kind
	void fire_region(int kind, const EventCtx &ctx, int64_t region_id);
	void check_regions();                          // enter/leave detection
	void begin_batch();                            // reset op budget + depth
	void start_frame(int body_node, int local_count, const EventCtx &ctx);
	bool run_frame(Frame &f); // returns true if DONE, false if SUSPENDED
	Value eval(Frame &f, int node);
	Value eval_binop(Frame &f, int node);
	std::vector<Value> eval_args(Frame &f, int off, int count);
	Value call_user(int func_id, const std::vector<Value> &args, const EventCtx &ctx);
	Value call_builtin(int id, const std::vector<Value> &args, Frame &f);
	Value order_unit(int64_t uid, int kind, int64_t x, int64_t y);
	Value order_group(const std::shared_ptr<std::vector<int64_t>> &grp,
			int kind, int64_t x, int64_t y);

	Value default_value(int type) const;
	bool truthy(const Value &v) const { return v.a != 0; }
	void emit_pres(PresRec r) { _pres.push_back(r); }

	// filter evaluation (group queries)
	bool passes_filter(const Value &filter, int64_t entity_id) const;
	std::shared_ptr<std::vector<int64_t>> make_group() const {
		return std::make_shared<std::vector<int64_t>>();
	}
};

} // namespace mrts
