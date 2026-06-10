class_name DRng
## Deterministic RNG owned by the sim. Never use randf()/randi() in sim code.
##
## splitmix32 variant: all intermediate values are masked to 32 bits so we
## never depend on integer overflow semantics. State is part of the sim's
## hashed state for desync detection.

const MASK32 := 0xFFFFFFFF

var state: int


func _init(seed_value: int) -> void:
	state = seed_value & MASK32


## Returns a uniformly distributed 32-bit unsigned int.
func next() -> int:
	state = (state + 0x9E3779B9) & MASK32
	var z := state
	z = ((z ^ (z >> 16)) * 0x21F0AAAD) & MASK32
	z = ((z ^ (z >> 15)) * 0x735A2D97) & MASK32
	return z ^ (z >> 15)


## Inclusive range. Modulo bias is acceptable for gameplay use.
func randi_range(lo: int, hi: int) -> int:
	assert(hi >= lo)
	return lo + next() % (hi - lo + 1)


## Random fixed-point value in [0, Fixed.ONE).
func rand_fixed() -> int:
	return next() & (Fixed.ONE - 1)
