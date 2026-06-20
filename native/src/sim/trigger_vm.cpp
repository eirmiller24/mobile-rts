#include "sim/trigger_vm.h"

#include <algorithm>

#include <godot_cpp/classes/object.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>
#include <godot_cpp/variant/packed_int64_array.hpp>
#include <godot_cpp/variant/packed_string_array.hpp>

#include "sim/command.h"
#include "sim/sim.h"

using namespace godot;

namespace mrts {

using namespace tir;

// ---------------------------------------------------------------------------
// Program marshalling
// ---------------------------------------------------------------------------
void TProgram::load(Object *prog) {
	nodes.clear(); lists.clear(); ints.clear(); strings.clear();
	globals.clear(); functions.clear(); events.clear();
	hash_value = 0;
	if (prog == nullptr) {
		return;
	}
	PackedInt32Array pn = prog->get("nodes");
	nodes.assign(pn.ptr(), pn.ptr() + pn.size());
	PackedInt32Array pl = prog->get("lists");
	lists.assign(pl.ptr(), pl.ptr() + pl.size());
	PackedInt64Array pi = prog->get("ints");
	ints.assign(pi.ptr(), pi.ptr() + pi.size());
	PackedStringArray ps = prog->get("strings");
	strings.reserve(ps.size());
	for (int i = 0; i < ps.size(); i++) {
		strings.push_back(ps[i]);
	}
	PackedInt32Array pg = prog->get("globals");
	globals.assign(pg.ptr(), pg.ptr() + pg.size());
	PackedInt32Array pf = prog->get("functions");
	functions.assign(pf.ptr(), pf.ptr() + pf.size());
	PackedInt32Array pe = prog->get("events");
	events.assign(pe.ptr(), pe.ptr() + pe.size());
	hash_value = (int64_t)prog->get("hash_value");
}

// ---------------------------------------------------------------------------
// Load / globals init
// ---------------------------------------------------------------------------
void TriggerVM::load(Sim *sim, Object *program) {
	_sim = sim;
	_prog.load(program);
	_glob.clear();
	_timers.clear();
	_suspended.clear();
	_pres.clear();
	_next_timer_id = 1;
	_next_frame_id = 1;
	_started = false;
	_region_seeded = false;
	_region_members.clear();
	_completed_pending.clear();
	_loaded = program != nullptr;
	_active = _prog.n_events() > 0;
	_has_region_events = false;
	for (int e = 0; e < _prog.n_events(); e++) {
		int k = _prog.events[e * EVENT_STRIDE];
		if (k == EV_UNIT_ENTERS_REGION || k == EV_UNIT_LEAVES_REGION) {
			_has_region_events = true;
		}
	}

	// Initialise globals to their typed zero, then run any init expressions in
	// ascending global id (they reference only constants / earlier globals).
	int ng = _prog.n_globals();
	_glob.resize(ng);
	for (int g = 0; g < ng; g++) {
		_glob[g] = default_value(_prog.globals[g * GLOBAL_STRIDE + 0]);
	}
	_ops = OP_BUDGET;
	_depth = 0;
	for (int g = 0; g < ng; g++) {
		int init = _prog.globals[g * GLOBAL_STRIDE + 1];
		if (init >= 0) {
			Frame tmp;
			_glob[g] = eval(tmp, init);
		}
	}
}

Value TriggerVM::default_value(int type) const {
	if (type == T_GROUP) {
		return {T_GROUP, 0, 0, make_group()};
	}
	if (type == T_POINT) {
		return {T_POINT, 0, 0, nullptr};
	}
	return {type, 0, 0, nullptr};
}

// ---------------------------------------------------------------------------
// The per-tick trigger phase
// ---------------------------------------------------------------------------
void TriggerVM::begin_batch() {
	_ops = OP_BUDGET;
	_depth = 0;
}

void TriggerVM::fire_kind(int kind, const EventCtx &ctx) {
	for (int e = 0; e < _prog.n_events(); e++) {
		if (_prog.events[e * EVENT_STRIDE] == kind) {
			run_event(e, ctx);
		}
	}
}

// Region events register against a specific region (operand p0); fire only the
// handlers whose region matches.
void TriggerVM::fire_region(int kind, const EventCtx &ctx, int64_t region_id) {
	for (int e = 0; e < _prog.n_events(); e++) {
		int base = e * EVENT_STRIDE;
		if (_prog.events[base] == kind && _prog.events[base + 1] == region_id) {
			run_event(e, ctx);
		}
	}
}

void TriggerVM::tick_phase() {
	if (!_active) {
		return;
	}
	begin_batch();
	int64_t tick = _sim->tick;

	if (!_started) {
		_started = true;
		fire_kind(EV_MAP_INIT, EventCtx());
		fire_kind(EV_MATCH_START, EventCtx());
	}

	// Drain deferred structure_completes (entities still present, §3.7).
	if (!_completed_pending.empty()) {
		std::vector<int64_t> done;
		done.swap(_completed_pending);
		for (int64_t cid : done) {
			EventCtx ctx;
			ctx.unit = cid;
			fire_kind(EV_STRUCTURE_COMPLETES, ctx);
		}
	}

	// Region enter/leave by position diff (one-tick latency vs movement).
	check_regions();

	// Resume suspended frames whose wait elapsed, ascending frame id (§3.7).
	if (!_suspended.empty()) {
		std::vector<Frame> due;
		std::vector<Frame> remain;
		for (Frame &f : _suspended) {
			if (f.resume_tick <= tick) {
				due.push_back(std::move(f));
			} else {
				remain.push_back(std::move(f));
			}
		}
		_suspended = std::move(remain);
		std::sort(due.begin(), due.end(),
				[](const Frame &a, const Frame &b) { return a.id < b.id; });
		for (Frame &f : due) {
			if (!run_frame(f)) {
				_suspended.push_back(std::move(f));
			}
		}
	}

	// Advance timers (ascending id); fire timer_expires for each that elapses.
	for (size_t i = 0; i < _timers.size(); i++) {
		VmTimer &t = _timers[i];
		if (!t.active) {
			continue;
		}
		t.remaining -= 1;
		if (t.remaining <= 0) {
			int64_t tid = t.id;
			if (t.repeating) {
				t.remaining = t.period;
			} else {
				t.active = false;
			}
			EventCtx ctx;
			ctx.timer = tid;
			fire_kind(EV_TIMER_EXPIRES, ctx);
		}
	}

	// every(period): fire on tick multiples (match_start owns tick 0).
	if (tick > 0) {
		for (int e = 0; e < _prog.n_events(); e++) {
			if (_prog.events[e * EVENT_STRIDE] != EV_EVERY) {
				continue;
			}
			int64_t period = _prog.events[e * EVENT_STRIDE + 1];
			if (period > 0 && tick % period == 0) {
				run_event(e, EventCtx());
			}
		}
	}
}

// ---------------------------------------------------------------------------
// Sim-system event hooks
// ---------------------------------------------------------------------------
void TriggerVM::fire_deaths(const std::vector<int64_t> &ids) {
	if (!_active || !_started) {
		return; // no unit_dies handlers can have run before match_start
	}
	begin_batch();
	for (int64_t id : ids) {
		EventCtx ctx;
		ctx.unit = id; // dying_unit(); killer (unit2) unknown for now
		fire_kind(EV_UNIT_DIES, ctx);
	}
}

void TriggerVM::note_structure_complete(int64_t id) {
	if (_active && _started) {
		_completed_pending.push_back(id);
	}
}

// Region enter/leave by position diff. First call (after match_start) seeds the
// baseline membership without firing; later calls diff and fire (ascending
// region id, then ascending unit id) — design_m5.md §3.7 deterministic ordering.
void TriggerVM::check_regions() {
	if (!_has_region_events || _sim->regions.empty()) {
		_region_seeded = true;
		return;
	}
	for (const Region &r : _sim->regions) {
		// Current occupants, ascending id.
		std::vector<int64_t> now;
		for (const Entity &e : _sim->entities) {
			if (!e.is_resource() && e.hp > 0 && r.contains(e.x, e.y)) {
				now.push_back(e.id);
			}
		}
		std::vector<int64_t> &prev = _region_members[r.id];
		if (_region_seeded) {
			// Entered = now \ prev.
			for (int64_t uid : now) {
				if (!std::binary_search(prev.begin(), prev.end(), uid)) {
					EventCtx ctx;
					ctx.unit = uid;
					ctx.region = r.id;
					fire_region(EV_UNIT_ENTERS_REGION, ctx, r.id);
				}
			}
			// Left = prev \ now.
			for (int64_t uid : prev) {
				if (!std::binary_search(now.begin(), now.end(), uid)) {
					EventCtx ctx;
					ctx.unit = uid;
					ctx.region = r.id;
					fire_region(EV_UNIT_LEAVES_REGION, ctx, r.id);
				}
			}
		}
		prev = std::move(now);
	}
	_region_seeded = true;
}

void TriggerVM::run_event(int ev_index, const EventCtx &ctx) {
	int base = ev_index * EVENT_STRIDE;
	int body = _prog.events[base + 4];
	int local_count = _prog.events[base + 5];
	start_frame(body, local_count, ctx);
}

void TriggerVM::start_frame(int body_node, int local_count, const EventCtx &ctx) {
	Frame f;
	f.id = _next_frame_id++;
	f.ctx = ctx;
	f.locals.resize(local_count);
	f.conts.push_back(Cont{body_node, 0, 0, 0, 0, nullptr});
	if (!run_frame(f)) {
		_suspended.push_back(std::move(f));
	}
}

// ---------------------------------------------------------------------------
// The iterative statement driver (handles wait via the explicit cont stack).
// Returns true when the frame is DONE, false when it SUSPENDED on a wait.
// ---------------------------------------------------------------------------
bool TriggerVM::run_frame(Frame &f) {
	while (!f.conts.empty()) {
		if (--_ops < 0) {
			f.conts.clear(); // op budget exhausted -> kill the trigger (§3.7)
			return true;
		}
		Cont &c = f.conts.back();
		int n = c.node;
		switch (_prog.op(n)) {
			case OP_BLOCK: {
				int off = _prog.a(n), cnt = _prog.b(n);
				if (c.pc < cnt) {
					int child = _prog.lists[off + c.pc];
					c.pc += 1;
					f.conts.push_back(Cont{child, 0, 0, 0, 0, nullptr});
				} else {
					f.conts.pop_back();
				}
				break;
			}
			case OP_LOCAL_DECL: {
				int slot = _prog.a(n), init = _prog.b(n), type = _prog.c(n);
				Value v = (init >= 0) ? eval(f, init) : default_value(type);
				f.locals[slot] = v;
				f.conts.pop_back();
				break;
			}
			case OP_ASSIGN_LOCAL: {
				int slot = _prog.a(n);
				Value v = eval(f, _prog.b(n));
				f.locals[slot] = v;
				f.conts.pop_back();
				break;
			}
			case OP_ASSIGN_GLOBAL: {
				int gid = _prog.a(n);
				Value v = eval(f, _prog.b(n));
				_glob[gid] = v;
				f.conts.pop_back();
				break;
			}
			case OP_EXPR_STMT: {
				eval(f, _prog.a(n));
				f.conts.pop_back();
				break;
			}
			case OP_IF: {
				Value cv = eval(f, _prog.a(n));
				int then_n = _prog.b(n), else_n = _prog.c(n);
				f.conts.pop_back();
				if (truthy(cv)) {
					f.conts.push_back(Cont{then_n, 0, 0, 0, 0, nullptr});
				} else if (else_n >= 0) {
					f.conts.push_back(Cont{else_n, 0, 0, 0, 0, nullptr});
				}
				break;
			}
			case OP_WHILE: {
				Value cv = eval(f, _prog.a(n));
				int body_n = _prog.b(n);
				if (truthy(cv)) {
					f.conts.push_back(Cont{body_n, 0, 0, 0, 0, nullptr});
				} else {
					f.conts.pop_back();
				}
				break;
			}
			case OP_FOR_NUM: {
				int slot = _prog.a(n), off = _prog.b(n);
				int body = _prog.lists[off + 3];
				if (c.pc == 0) {
					int64_t start = eval(f, _prog.lists[off + 0]).a;
					c.s1 = eval(f, _prog.lists[off + 1]).a; // end
					c.s2 = eval(f, _prog.lists[off + 2]).a; // step
					c.s0 = start;
					c.pc = 1;
				} else {
					c.s0 += c.s2;
				}
				bool go = (c.s2 >= 0) ? (c.s0 <= c.s1) : (c.s0 >= c.s1);
				f.locals[slot] = Value::int_v(c.s0);
				if (go) {
					f.conts.push_back(Cont{body, 0, 0, 0, 0, nullptr});
				} else {
					f.conts.pop_back();
				}
				break;
			}
			case OP_FOR_EACH: {
				int slot = _prog.b(n), body = _prog.c(n);
				if (c.pc == 0) {
					Value g = eval(f, _prog.a(n));
					c.grp = g.grp ? g.grp : make_group();
					c.s0 = 0;
					c.pc = 1;
				}
				if (c.s0 < (int64_t)c.grp->size()) {
					f.locals[slot] = Value::ref_v(T_UNIT, (*c.grp)[c.s0]);
					c.s0 += 1;
					f.conts.push_back(Cont{body, 0, 0, 0, 0, nullptr});
				} else {
					f.conts.pop_back();
				}
				break;
			}
			case OP_BREAK: {
				// Unwind to and including the nearest enclosing loop cont.
				while (!f.conts.empty()) {
					int op = _prog.op(f.conts.back().node);
					f.conts.pop_back();
					if (op == OP_WHILE || op == OP_FOR_NUM || op == OP_FOR_EACH) {
						break;
					}
				}
				break;
			}
			case OP_RETURN: {
				if (_prog.a(n) >= 0) {
					f.ret = eval(f, _prog.a(n));
				}
				f.returned = true;
				f.conts.clear();
				return true;
			}
			case OP_WAIT: {
				int64_t dur = eval(f, _prog.a(n)).a;
				f.conts.pop_back();
				f.resume_tick = _sim->tick + (dur > 0 ? dur : 0);
				return false; // SUSPENDED
			}
			default:
				f.conts.pop_back();
				break;
		}
	}
	return true;
}

// ---------------------------------------------------------------------------
// Expression evaluation (recursive; never suspends)
// ---------------------------------------------------------------------------
Value TriggerVM::eval(Frame &f, int n) {
	if (--_ops < 0) {
		return Value::int_v(0);
	}
	switch (_prog.op(n)) {
		case OP_LIT_INT:
			return Value::int_v(_prog.ints[_prog.a(n)]);
		case OP_LIT_FIXED:
			return Value::fixed_v(_prog.ints[_prog.a(n)]);
		case OP_LIT_BOOL:
			return Value::bool_v(_prog.a(n) != 0);
		case OP_LIT_NULL:
			return {_prog.t(n), 0, 0, nullptr};
		case OP_LIT_STR:
			return {T_STRING, _prog.a(n), 0, nullptr};
		case OP_CONST:
			return {_prog.t(n), _prog.a(n), 0, nullptr};
		case OP_GLOBAL_GET:
			return _glob[_prog.a(n)];
		case OP_LOCAL_GET:
			return f.locals[_prog.a(n)];
		case OP_UNOP: {
			Value v = eval(f, _prog.a(n));
			if (_prog.b(n) == UN_NOT) {
				return Value::bool_v(v.a == 0);
			}
			return {_prog.t(n), -v.a, 0, nullptr}; // NEG (raw works for int+fixed)
		}
		case OP_BINOP:
			return eval_binop(f, n);
		case OP_CALL: {
			std::vector<Value> args = eval_args(f, _prog.b(n), _prog.c(n));
			return call_user(_prog.a(n), args, f.ctx);
		}
		case OP_BUILTIN: {
			std::vector<Value> args = eval_args(f, _prog.b(n), _prog.c(n));
			return call_builtin(_prog.a(n), args, f);
		}
	}
	return Value::int_v(0);
}

std::vector<Value> TriggerVM::eval_args(Frame &f, int off, int count) {
	std::vector<Value> args;
	args.reserve(count);
	for (int i = 0; i < count; i++) {
		args.push_back(eval(f, _prog.lists[off + i]));
	}
	return args;
}

Value TriggerVM::eval_binop(Frame &f, int n) {
	int op = _prog.c(n);
	int rt = _prog.t(n);
	if (op == BIN_AND) {
		Value l = eval(f, _prog.a(n));
		if (!truthy(l)) {
			return Value::bool_v(false);
		}
		return Value::bool_v(truthy(eval(f, _prog.b(n))));
	}
	if (op == BIN_OR) {
		Value l = eval(f, _prog.a(n));
		if (truthy(l)) {
			return Value::bool_v(true);
		}
		return Value::bool_v(truthy(eval(f, _prog.b(n))));
	}
	Value l = eval(f, _prog.a(n));
	Value r = eval(f, _prog.b(n));
	switch (op) {
		case BIN_EQ:
			return Value::bool_v(l.a == r.a && (l.type != T_POINT || l.b == r.b));
		case BIN_NE:
			return Value::bool_v(!(l.a == r.a && (l.type != T_POINT || l.b == r.b)));
		case BIN_LT: return Value::bool_v(l.a < r.a);
		case BIN_LE: return Value::bool_v(l.a <= r.a);
		case BIN_GT: return Value::bool_v(l.a > r.a);
		case BIN_GE: return Value::bool_v(l.a >= r.a);
		case BIN_ADD: return {rt, l.a + r.a, 0, nullptr};
		case BIN_SUB: return {rt, l.a - r.a, 0, nullptr};
		case BIN_MUL:
			return {rt, rt == T_FIXED ? Fixed::mul(l.a, r.a) : l.a * r.a, 0, nullptr};
		case BIN_DIV:
			if (r.a == 0) {
				return {rt, 0, 0, nullptr};
			}
			return {rt, rt == T_FIXED ? Fixed::div(l.a, r.a) : l.a / r.a, 0, nullptr};
		case BIN_MOD:
			return {rt, r.a == 0 ? 0 : l.a % r.a, 0, nullptr};
	}
	return Value::int_v(0);
}

Value TriggerVM::call_user(int func_id, const std::vector<Value> &args, const EventCtx &ctx) {
	int base = func_id * FUNC_STRIDE;
	int param_count = _prog.functions[base + 0];
	int local_count = _prog.functions[base + 1];
	int ret_type = _prog.functions[base + 2];
	int body = _prog.functions[base + 3];
	if (_depth >= CALL_DEPTH_CAP) {
		return default_value(ret_type); // recursion cap (§3.7)
	}
	Frame g;
	g.id = _next_frame_id++;
	g.ctx = ctx;
	g.locals.resize(local_count);
	for (int i = 0; i < param_count && i < (int)args.size(); i++) {
		g.locals[i] = args[i];
	}
	g.conts.push_back(Cont{body, 0, 0, 0, 0, nullptr});
	_depth += 1;
	run_frame(g); // functions never wait -> always DONE
	_depth -= 1;
	return g.returned ? g.ret : default_value(ret_type);
}

// ---------------------------------------------------------------------------
// Presentation drain (unhashed view output, §3.4)
// ---------------------------------------------------------------------------
Array TriggerVM::drain_presentation() {
	Array out;
	for (const PresRec &r : _pres) {
		Dictionary d;
		d["kind"] = r.kind;
		d["who"] = r.who;
		if (r.kind == 0) {
			d["text"] = (r.str_idx >= 0 && r.str_idx < (int)_prog.strings.size())
					? _prog.strings[r.str_idx] : String();
		} else {
			d["x"] = r.x;
			d["y"] = r.y;
		}
		out.push_back(d);
	}
	_pres.clear();
	return out;
}

// ---------------------------------------------------------------------------
// Hash (all mutable trigger state, §3.6)
// ---------------------------------------------------------------------------
int64_t TriggerVM::hash_into(int64_t h) const {
	// A sim with no trigger program (every M4 parity scenario) contributes
	// nothing, so the native hash stays bit-exact with the trigger-less GDScript
	// oracle (design_m5.md §2.4). Trigger maps are verified native-vs-native by
	// determinism instead of parity.
	if (!_loaded) {
		return h;
	}
	h = SimHash::mix(h, _prog.hash_value);
	h = SimHash::mix(h, _started ? 1 : 0);
	h = SimHash::mix(h, _next_timer_id);
	h = SimHash::mix(h, _next_frame_id);
	for (const Value &v : _glob) {
		h = v.hash_into(h);
	}
	for (const VmTimer &t : _timers) {
		h = SimHash::mix(h, t.id);
		h = SimHash::mix(h, t.remaining);
		h = SimHash::mix(h, t.period);
		h = SimHash::mix(h, t.repeating ? 1 : 0);
		h = SimHash::mix(h, t.active ? 1 : 0);
	}
	for (const Frame &f : _suspended) {
		h = f.hash_into(h);
	}
	h = SimHash::mix(h, _region_seeded ? 1 : 0);
	for (const auto &kv : _region_members) { // std::map -> ascending region id
		h = SimHash::mix(h, kv.first);
		for (int64_t uid : kv.second) {
			h = SimHash::mix(h, uid);
		}
	}
	for (int64_t cid : _completed_pending) {
		h = SimHash::mix(h, cid);
	}
	return h;
}

} // namespace mrts
