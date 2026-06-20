#pragma once
// WC3-style pseudo-random proc distribution. Bit-exact port of
// src/sim/proc_rng.gd. A proc rolls `base + stacks*bonus` where `stacks`
// counts consecutive failures; success resets the stack.
//
// Stacks live in the owning entity's `procs` map (keyed by proc name) so they
// are part of the hashed sim state, and rolls consume the sim's DRng — call
// only from inside the sim, in deterministic order.

#include <cstdint>
#include <map>
#include <string>
#include "sim/drng.h"
#include "sim/fixed.h"

namespace mrts {

// Proc stacks: keyed by proc name, ordered lexicographically (std::map keeps
// the same byte order GDScript's String.sort uses for ASCII keys), which the
// entity hash folds in order — matching SimEntity.hash_into.
using ProcStacks = std::map<std::string, int64_t>;

struct ProcRng {
	static inline bool roll(DRng &rng, ProcStacks &stacks, const std::string &key,
			int64_t base, int64_t bonus) {
		auto it = stacks.find(key);
		int64_t n = (it == stacks.end()) ? 0 : it->second;
		int64_t chance = base + n * bonus;
		if (rng.rand_fixed() < chance) {
			if (it != stacks.end()) {
				stacks.erase(it);
			}
			return true;
		}
		stacks[key] = n + 1;
		return false;
	}

	static inline int64_t max_failures(int64_t base, int64_t bonus) {
		if (base >= Fixed::ONE) {
			return 0;
		}
		if (bonus <= 0) {
			return -1;
		}
		return (Fixed::ONE - base + bonus - 1) / bonus;
	}
};

} // namespace mrts
