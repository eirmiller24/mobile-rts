class_name ProcRng
extends RefCounted
## WC3-style pseudo-random proc distribution (design.md "Pseudo-random
## procs"). A proc rolls `base + stacks * bonus` where `stacks` counts
## consecutive failures; success resets the stack. Both parameters are
## fixed-point fractions of Fixed.ONE and are independent catalog fields —
## map makers tune them separately (bonus 0 = true constant chance).
##
## Stacks live in the owning entity's `procs` Dictionary (keyed by proc
## name) so they are part of the hashed sim state. Rolls consume the sim's
## DRng, so only call this from inside the sim, in deterministic order.


## Roll the proc keyed `key` in `stacks`, with `base` chance and per-failure
## `bonus` (both fixed-point in [0, Fixed.ONE]). Mutates `stacks` and `rng`.
static func roll(rng: DRng, stacks: Dictionary, key: String, base: int, bonus: int) -> bool:
	var n: int = stacks.get(key, 0)
	var chance := base + n * bonus
	if rng.rand_fixed() < chance:
		stacks.erase(key)
		return true
	stacks[key] = n + 1
	return false


## Worst case rolls until a guaranteed success (UI/tooling helper).
static func max_failures(base: int, bonus: int) -> int:
	if base >= Fixed.ONE:
		return 0
	if bonus <= 0:
		return -1 # never guaranteed
	return (Fixed.ONE - base + bonus - 1) / bonus
