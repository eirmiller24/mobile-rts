class_name SimPlayer
extends RefCounted
## Per-player sim state (design_m3.md §4.1). Resource balances are fixed
## point so fractional per-tick income accrues exactly; the UI displays
## the floor. Bandwidth is deliberately NOT stored — it is derived from
## live structures/units on query so it can never drift from the truth it
## summarizes.

var id: int = 0
## Interned faction name (SimHash.fnv_string).
var faction: int = 0
## Resource balances, fixed point.
var alloy: int = 0
var flux: int = 0


func hash_into(h: int) -> int:
	for v: int in [id, faction, alloy, flux]:
		h = (h * 31 + v) & 0x7FFFFFFFFFFFFFF
	return h
