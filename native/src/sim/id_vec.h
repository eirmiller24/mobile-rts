#pragma once
// Dense id-indexed store for sim entities/players. Replaces std::map<id,T> with
// a contiguous std::vector indexed by id, plus a presence bitmap (a slot can be
// absent while index 0 — the neutral player — is a valid present id, so an
// id==0 sentinel won't do).
//
// Why: the hot per-unit-per-neighbor loops only touch a few fields; contiguous
// storage keeps the working set in cache and avoids the red-black-tree pointer
// chase (see the AoS/SoA discussion — this is the orthogonal, bigger win).
//
// Determinism: ids are assigned strictly increasing and never reused (GDScript
// semantics), so dead entries are tombstones (present=false), never recycled —
// reusing an id would change the sim. Iteration is ascending id and skips
// holes, matching both the GDScript Dictionary insertion order (== ascending,
// since inserts are id-ordered) and _sorted_ids().
//
// Reference stability: like a vector, put() can reallocate and invalidate
// references/pointers to existing elements. Callers must not hold a T& across a
// put()/spawn; re-fetch by id. (reserve() up front keeps reallocation rare.)
//
// T must have an `int64_t id` field.

#include <cstdint>
#include <type_traits>
#include <vector>

namespace mrts {

template <typename T>
class IdVec {
	std::vector<T> _data;
	std::vector<uint8_t> _present;
	int64_t _count = 0;

	void _ensure(int64_t id) {
		if ((size_t)id >= _present.size()) {
			_data.resize((size_t)id + 1);
			_present.resize((size_t)id + 1, 0);
		}
	}

public:
	void reserve(int64_t n) {
		_data.reserve((size_t)n);
		_present.reserve((size_t)n);
	}

	// Insert or overwrite the entry at id; returns a reference to it.
	T &put(int64_t id, const T &v) {
		_ensure(id);
		if (!_present[id]) {
			_present[id] = 1;
			_count++;
		}
		_data[id] = v;
		return _data[id];
	}

	T *find(int64_t id) {
		if (id < 0 || (size_t)id >= _present.size() || !_present[id]) {
			return nullptr;
		}
		return &_data[id];
	}
	const T *find(int64_t id) const {
		if (id < 0 || (size_t)id >= _present.size() || !_present[id]) {
			return nullptr;
		}
		return &_data[id];
	}

	bool has(int64_t id) const {
		return id >= 0 && (size_t)id < _present.size() && _present[id];
	}

	void erase(int64_t id) {
		if (has(id)) {
			_present[id] = 0;
			_count--;
		}
	}

	int64_t size() const { return _count; }

	// Forward iterator over present entries, ascending id.
	template <bool Const>
	class Iter {
		using Store = typename std::conditional<Const, const IdVec, IdVec>::type;
		using Ref = typename std::conditional<Const, const T &, T &>::type;
		Store *_o;
		size_t _i;
		void _advance() {
			while (_i < _o->_present.size() && !_o->_present[_i]) {
				_i++;
			}
		}

	public:
		Iter(Store *o, size_t i) : _o(o), _i(i) { _advance(); }
		Ref operator*() const { return _o->_data[_i]; }
		Iter &operator++() {
			_i++;
			_advance();
			return *this;
		}
		bool operator!=(const Iter &other) const { return _i != other._i; }
	};

	Iter<false> begin() { return Iter<false>(this, 0); }
	Iter<false> end() { return Iter<false>(this, _present.size()); }
	Iter<true> begin() const { return Iter<true>(this, 0); }
	Iter<true> end() const { return Iter<true>(this, _present.size()); }
};

} // namespace mrts
