class_name MapData
extends RefCounted
## A parsed map (design_m3.md §3): a deliberate subset of the M5 bundle.
## Plain data — the sim consumes it at construction and never reads a file.
## Map content participates in determinism the same way the catalog does:
## hash_value folds into the initial state hash, so peers with different
## map files desync at tick 0.

var name := ""
var version := 1
var errors := PackedStringArray()

## Compiled from the map's declared catalog_layers.
var catalog: CompiledCatalog

var tiles_w := 64
var tiles_h := 64

## {id: int (>= 1; 0 is reserved for neutral), faction: String,
##  start_alloy: int, start_flux: int}
var players: Array[Dictionary] = []

## Normalized spawn specs, in authored order (spawn order assigns entity
## ids, so the order is part of the map's identity):
##  structures/resources: {type_key, type, player, cx, cy, completed}
##  units:                {type_key, type, player, x, y}  (fixed coords)
var objects: Array[Dictionary] = []

## Faction-agnostic start anchors (design_m4.md §13): {player, cx, cy} in
## pathing cells. A match setup spawns each player's chosen faction loadout
## here, so the same map plays any faction matchup. Not folded into the
## hash — the spawned objects it produces are (via rehash after setup).
var starts: Array[Dictionary] = []

## SimHash over tiles, players, and objects.
var hash_value := 0


func ok() -> bool:
	return errors.is_empty() and catalog != null and catalog.ok()


## Empty map for tests and tools: no players, no objects.
static func blank(p_tiles_w: int, p_tiles_h: int) -> MapData:
	var m := MapData.new()
	m.tiles_w = p_tiles_w
	m.tiles_h = p_tiles_h
	m.rehash()
	return m


## Recompute hash_value from current content (loader calls this; tests
## that build MapData by hand must call it after mutating).
func rehash() -> void:
	var buf := PackedByteArray()
	SimHash.fold_value(buf, tiles_w)
	SimHash.fold_value(buf, tiles_h)
	var by_id := players.duplicate()
	by_id.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return a["id"] < b["id"])
	SimHash.fold_value(buf, by_id)
	SimHash.fold_value(buf, objects)
	hash_value = SimHash.fnv_bytes(buf)
