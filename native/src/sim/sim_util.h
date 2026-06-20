#pragma once
// GDScript integer-builtin equivalents, so ported sim math reads 1:1 with the
// GDScript reference (maxi/mini/absi/clampi over int64).

#include <cstdint>

namespace mrts {

inline int64_t maxi(int64_t a, int64_t b) { return a > b ? a : b; }
inline int64_t mini(int64_t a, int64_t b) { return a < b ? a : b; }
inline int64_t absi(int64_t a) { return a < 0 ? -a : a; }
inline int64_t clampi(int64_t v, int64_t lo, int64_t hi) {
	return v < lo ? lo : (v > hi ? hi : v);
}

} // namespace mrts
