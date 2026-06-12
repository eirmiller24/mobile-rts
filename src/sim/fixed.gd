class_name Fixed
## Fixed-point math for the deterministic sim. 16.16 format stored in int.
##
## All sim arithmetic goes through this class. Floats are forbidden inside
## the sim; from_float/to_float exist only for the view layer and tooling.

const SHIFT := 16
const ONE := 1 << SHIFT
const HALF := ONE >> 1


static func from_int(i: int) -> int:
	return i << SHIFT


## View layer / tooling only — never call from sim code.
static func from_float(f: float) -> int:
	return int(roundf(f * ONE))


## View layer / tooling only — never call from sim code.
static func to_float(a: int) -> float:
	return a / float(ONE)


static func to_int(a: int) -> int:
	return a >> SHIFT


static func mul(a: int, b: int) -> int:
	return (a * b) >> SHIFT


static func div(a: int, b: int) -> int:
	return (a << SHIFT) / b


static func floor(a: int) -> int:
	return a & ~(ONE - 1)


static func round(a: int) -> int:
	return Fixed.floor(a + HALF)


## Integer Newton's method; deterministic across platforms. Seeded just
## above sqrt(raw) via bit length (~4 iterations instead of ~20 from a
## naive seed). The iterate is strictly decreasing until convergence, so
## it cannot oscillate (the naive `while x != prev` form loops forever on
## inputs like raw = k^2 + 2k).
static func sqrt(a: int) -> int:
	assert(a >= 0)
	if a == 0:
		return 0
	var raw := a << SHIFT
	var bits := 0
	var t := raw
	while t > 0:
		t >>= 1
		bits += 1
	# raw < 2^bits, so 2^ceil(bits/2) > sqrt(raw): a valid upper seed.
	var x := 1 << ((bits + 1) >> 1)
	var y := (x + raw / x) >> 1
	while y < x:
		x = y
		y = (x + raw / x) >> 1
	return x
