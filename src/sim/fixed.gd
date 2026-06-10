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


## Integer Newton's method; deterministic across platforms.
static func sqrt(a: int) -> int:
	assert(a >= 0)
	if a == 0:
		return 0
	var raw := a << SHIFT
	var x := raw
	var prev := 0
	while x != prev:
		prev = x
		x = (x + raw / x) >> 1
	return x
