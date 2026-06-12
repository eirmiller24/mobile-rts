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


## Parse a decimal string ("2.5", "-0.25") straight to 16.16 fixed point
## without ever touching a float — catalog fixed values are sim inputs, so
## their parse must be deterministic by construction (see design_m3.md
## "Field types and fixed-point authoring"). Rounds half away from zero.
## Callers (the catalog compiler) validate format; bad input asserts here.
static func from_decimal(s: String) -> int:
	var neg := s.begins_with("-")
	var body := s.substr(1) if neg else s
	var dot := body.find(".")
	var int_part := body if dot == -1 else body.substr(0, dot)
	var frac_part := "" if dot == -1 else body.substr(dot + 1)
	assert(not int_part.is_empty() or not frac_part.is_empty(),
			"empty decimal string")
	var v := 0
	for ch in int_part:
		assert(ch >= "0" and ch <= "9", "bad decimal string")
		v = v * 10 + (ch.unicode_at(0) - 48)
	v <<= SHIFT
	if not frac_part.is_empty():
		assert(frac_part.length() <= 9, "fractional part too long")
		var num := 0
		var den := 1
		for ch in frac_part:
			assert(ch >= "0" and ch <= "9", "bad decimal string")
			num = num * 10 + (ch.unicode_at(0) - 48)
			den *= 10
		v += (num * ONE * 2 + den) / (2 * den)
	return -v if neg else v


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
