#pragma once
// Deterministic RNG owned by the sim. Bit-exact port of src/sim/drng.gd.
//
// splitmix32 variant: every intermediate is masked to 32 bits, so the stream
// never depends on integer-overflow semantics. State is part of the hashed sim
// state. Never use engine randomness in the sim.

#include <cstdint>
#include "sim/fixed.h"

namespace mrts {

struct DRng {
	static constexpr int64_t MASK32 = 0xFFFFFFFF;

	int64_t state = 0;

	DRng() = default;
	explicit DRng(int64_t seed_value) { state = seed_value & MASK32; }

	// Uniformly distributed 32-bit unsigned value (as a positive int64).
	inline int64_t next() {
		state = (state + 0x9E3779B9) & MASK32;
		int64_t z = state;
		z = ((z ^ (z >> 16)) * 0x21F0AAAD) & MASK32;
		z = ((z ^ (z >> 15)) * 0x735A2D97) & MASK32;
		return z ^ (z >> 15);
	}

	// Inclusive range; modulo bias acceptable for gameplay use.
	inline int64_t randi_range(int64_t lo, int64_t hi) {
		return lo + next() % (hi - lo + 1);
	}

	// Random fixed-point value in [0, Fixed::ONE).
	inline int64_t rand_fixed() { return next() & (Fixed::ONE - 1); }
};

} // namespace mrts
