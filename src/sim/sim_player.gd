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

## M4 Rebel economy intent dials (design_m4.md §3.2). Sim-side so the
## approximation runs identically on every peer; set by SET_ECONOMY (and
## nudged by manual MINE orders). Ratios are fixed 0..1.
var worker_target: int = 0          # desired worker headcount (auto-replace)
var alloy_flux_ratio: int = Fixed.ONE   # harvest split; 1.0 = all alloy
var build_mine_ratio: int = 0       # fraction of the pool held as build reserve
var auto_repair: bool = false

## M4 win/loss (design_m4.md §7.2): tick the player was first eliminated
## (no COMPLETE is_main structure), latched and never cleared. -1 = alive.
## had_main guards the rule so a player who never owned a main (e.g. neutral
## player 0) is never "eliminated"; elimination latches only after losing one.
var eliminated_tick: int = -1
var had_main: bool = false

## M4 drawn walls (design_m4.md §4.4): the ordered queue of pending wall
## segment cells (stroke order) and the worker id claiming each (0 = free).
## Pending segments block nothing and cost nothing until a worker starts one.
var wall_cells := PackedInt32Array()
var wall_claims := PackedInt32Array()
var wall_type: int = -1   # barricade type_key for the current plan


func hash_into(h: int) -> int:
	for v: int in [id, faction, alloy, flux, worker_target, alloy_flux_ratio,
			build_mine_ratio, int(auto_repair), eliminated_tick, int(had_main),
			wall_type]:
		h = (h * 31 + v) & 0x7FFFFFFFFFFFFFF
	for v in wall_cells:
		h = (h * 31 + v) & 0x7FFFFFFFFFFFFFF
	for v in wall_claims:
		h = (h * 31 + v) & 0x7FFFFFFFFFFFFFF
	return h
