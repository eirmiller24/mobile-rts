class_name TriggerProgram
extends RefCounted
## The compiled trigger program — the flat, interned IR the C++ VM walks
## (docs/trigger_ir.md). Plain data; produced by TriggerCompiler, handed to the
## native sim at construction alongside the catalog and map. The native loader
## reads these fields via Object.get(), so the names here are the contract.
##
## hash_value folds into Sim.state_hash() (design_m5.md §3.9): the *compiled
## program* is hashed, not the source, so comments/whitespace can't desync a
## replay and string constants (presentation only) never enter the hash.

var nodes := PackedInt32Array()      # stride TriggerIR.NODE_STRIDE
var lists := PackedInt32Array()      # pooled node-index lists
var ints := PackedInt64Array()       # int + fixed literal constants
var strings := PackedStringArray()   # presentation-only string pool
var globals := PackedInt32Array()    # stride GLOBAL_STRIDE: [type, init_node]
var functions := PackedInt32Array()  # stride FUNC_STRIDE
var events := PackedInt32Array()      # stride EVENT_STRIDE

var hash_value := 0
var errors := PackedStringArray()


func ok() -> bool:
	return errors.is_empty()


## Recompute hash_value over the compiled program (every flat array, in order).
## Folded into the initial state hash so a tampered program desyncs at tick 0.
func rehash() -> void:
	var buf := PackedByteArray()
	SimHash.fold_value(buf, nodes)
	SimHash.fold_value(buf, lists)
	SimHash.fold_value(buf, ints)
	# Strings are presentation-only and never hashed; their *count* is folded so
	# a structural change (a missing display_message) still shifts the hash.
	SimHash.fold_value(buf, strings.size())
	SimHash.fold_value(buf, globals)
	SimHash.fold_value(buf, functions)
	SimHash.fold_value(buf, events)
	hash_value = SimHash.fnv_bytes(buf)


## An empty program (no triggers) — the degenerate case a map without a
## triggers.lua produces. hash_value is stable.
static func empty() -> TriggerProgram:
	var p := TriggerProgram.new()
	p.rehash()
	return p
