#pragma once
// Fixed-point math for the deterministic sim. 16.16 format stored in int64.
// Bit-exact port of src/sim/fixed.gd (the frozen GDScript reference / oracle,
// design_m5.md §2.4).
//
// Determinism notes (design.md "Porting semantics to watch"):
//  - GDScript ints are 64-bit; arithmetic wraps two's-complement. Signed
//    overflow is UB in C++, so every step that can overflow is computed in
//    uint64_t (well-defined wrap) and cast back to int64_t, which reproduces
//    GDScript's result exactly while staying defined.
//  - GDScript `>>` is an arithmetic shift; g++ shifts int64_t arithmetically.
//  - GDScript `/` truncates toward zero; so does C++ integer `/`.
//
// from_float/to_float are intentionally absent: they exist only in the view
// layer (floats are forbidden in the sim).

#include <cstdint>

namespace mrts {

struct Fixed {
	static constexpr int SHIFT = 16;
	static constexpr int64_t ONE = 1LL << SHIFT;
	static constexpr int64_t HALF = ONE >> 1;

	static inline int64_t from_int(int64_t i) { return i << SHIFT; }
	static inline int64_t to_int(int64_t a) { return a >> SHIFT; }

	// (a * b) >> SHIFT, matching GDScript's wrapping 64-bit multiply.
	static inline int64_t mul(int64_t a, int64_t b) {
		return (int64_t)((uint64_t)a * (uint64_t)b) >> SHIFT;
	}

	// (a << SHIFT) / b, with the shift computed as a wrapping 64-bit op.
	static inline int64_t div(int64_t a, int64_t b) {
		return (int64_t)((uint64_t)a << SHIFT) / b;
	}

	static inline int64_t floor(int64_t a) { return a & ~(ONE - 1); }
	static inline int64_t round(int64_t a) { return floor(a + HALF); }

	// Integer Newton's method, deterministic across platforms. Direct port
	// of Fixed.sqrt — strictly decreasing iterate seeded just above the root.
	static inline int64_t sqrt(int64_t a) {
		// assert(a >= 0)
		if (a == 0) {
			return 0;
		}
		int64_t raw = a << SHIFT;
		int bits = 0;
		int64_t t = raw;
		while (t > 0) {
			t >>= 1;
			bits += 1;
		}
		int64_t x = 1LL << ((bits + 1) >> 1);
		int64_t y = (x + raw / x) >> 1;
		while (y < x) {
			x = y;
			y = (x + raw / x) >> 1;
		}
		return x;
	}
};

} // namespace mrts
