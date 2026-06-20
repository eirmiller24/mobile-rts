#pragma once
// Byte-level hashing the sim owns. Bit-exact port of src/sim/sim_hash.gd.
//
// FNV-1a, 32-bit variant: every intermediate fits in 64 bits, so nothing
// depends on overflow semantics. This is the definition compared across
// peers, replays, and the GDScript/C++ implementations, so it must match
// sim_hash.gd byte for byte.
//
// fold_value (the structured catalog/map serializer) is NOT ported: those
// content hashes are computed once in GDScript (CompiledCatalog.hash_value /
// MapData.hash_value) and handed to the native sim as plain ints. The native
// side only needs raw-byte and string hashing.

#include <cstdint>
#include <string>
#include <cstddef>

namespace mrts {

struct SimHash {
	static constexpr int64_t FNV_OFFSET = 0x811C9DC5;
	static constexpr int64_t FNV_PRIME = 0x01000193;
	static constexpr int64_t MASK32 = 0xFFFFFFFF;

	static inline int64_t fnv_bytes(const uint8_t *bytes, size_t n) {
		int64_t h = FNV_OFFSET;
		for (size_t i = 0; i < n; i++) {
			h = ((h ^ (int64_t)bytes[i]) * FNV_PRIME) & MASK32;
		}
		return h;
	}

	// Hash a UTF-8 byte sequence (proc names, faction names). Callers pass the
	// already-UTF-8 bytes of the Godot String.
	static inline int64_t fnv_string(const std::string &s) {
		return fnv_bytes(reinterpret_cast<const uint8_t *>(s.data()), s.size());
	}

	// The state-hash accumulator used everywhere a value folds into
	// state_hash(): `h = (h * 31 + v) & 0x7FFFFFFFFFFFFFF`. GDScript's signed
	// 64-bit multiply overflows and wraps; computing in uint64_t and masking
	// to the low 59 bits reproduces that exactly without signed-overflow UB.
	static constexpr int64_t STATE_MASK = 0x7FFFFFFFFFFFFFFLL;

	static inline int64_t mix(int64_t h, int64_t v) {
		return (int64_t)(((uint64_t)h * 31u + (uint64_t)v) & (uint64_t)STATE_MASK);
	}
};

} // namespace mrts
