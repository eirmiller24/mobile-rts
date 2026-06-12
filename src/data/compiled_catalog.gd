class_name CompiledCatalog
extends RefCounted
## Output of CatalogCompiler (design_m3.md §2.4): every entry's `sim` block
## already validated and converted to ints/Fixed/ticks, ids interned to
## type_keys, plus the damage class matrix, global constants, and a content
## hash that folds into Sim.state_hash() so mismatched data files desync at
## tick 0 instead of mid-game.
##
## This object is plain data — Dictionaries, packed arrays, ints. The sim
## never reads a file and never sees a string stat; everything it consumes
## is already compiled. `view`/`ui` blocks ride alongside for the far side
## of the determinism wall and are NOT part of the hash.

## Compile problems; a non-empty list means the catalog is unusable.
var errors := PackedStringArray()

## All entry ids, sorted lexicographically; index = type_key.
var ids := PackedStringArray()
## id -> type_key.
var _key_of := {}
## By type_key: kind string, compiled sim block, raw view/ui blocks.
var kinds: Array[String] = []
var sim_blocks: Array[Dictionary] = []
var view_blocks: Array[Dictionary] = []
var ui_blocks: Array[Dictionary] = []

## Damage/armor class names; index = the int compiled into entries.
var attack_classes := PackedStringArray()
var armor_classes := PackedStringArray()
## Flat damage multiplier matrix (fixed), [attack * n_armor + armor].
var matrix := PackedInt64Array()

## Global sim constants from the classes entry, already compiled
## (capsule_time -> ticks, rates -> fixed): capsule_time, capsule_hp,
## alloy_rate, flux_rate, assist_rate, repair_rate.
var globals := {}

## Aura marker flag -> PackedInt32Array of granting ability type_keys,
## resolved at compile time (design_m3.md §4.3).
var flag_abilities := {}

## SimHash over kinds, ids, and compiled sim blocks in key order.
var hash_value: int = 0


func ok() -> bool:
	return errors.is_empty()


## -1 if the id doesn't exist.
func key_of(id: String) -> int:
	return _key_of.get(id, -1)


func id_of(key: int) -> String:
	return ids[key]


func has_id(id: String) -> bool:
	return _key_of.has(id)


func size() -> int:
	return ids.size()


func kind_of(key: int) -> String:
	return kinds[key]


func sim_of(key: int) -> Dictionary:
	return sim_blocks[key]


func view_of(key: int) -> Dictionary:
	return view_blocks[key]


func ui_of(key: int) -> Dictionary:
	return ui_blocks[key]


## Damage multiplier (fixed) for an attack/armor class pair. Unset classes
## (-1) take no multiplier.
func class_mul(attack: int, armor: int) -> int:
	if attack < 0 or armor < 0:
		return Fixed.ONE
	return matrix[attack * armor_classes.size() + armor]


## Ability type_keys granting `flag` (e.g. "territory"); empty if none.
func abilities_with_flag(flag: String) -> PackedInt32Array:
	return flag_abilities.get(flag, PackedInt32Array())


## Internal — only CatalogCompiler builds these mappings.
func _set_interning(sorted_ids: PackedStringArray) -> void:
	ids = sorted_ids
	_key_of.clear()
	for i in ids.size():
		_key_of[ids[i]] = i
