class_name MatchSetup
## Turns a faction-agnostic map (resources + start anchors) into a concrete
## match by spawning each player's chosen faction loadout at their anchor
## (design_m4.md §13: the same clash map plays any faction matchup, and a
## pre-match screen lets the human pick sides and hand the bots a faction).
##
## This lives outside the determinism wall — it mutates MapData (plain spawn
## data) before Sim construction. After it runs, MapData.rehash() folds the
## spawned objects + chosen factions back into the map hash, so two peers who
## picked different factions desync at tick 0 exactly like a different map.

## faction -> { main: type string, units: [{type, ox, oy}] }. Offsets are in
## tiles from the main's anchor tile, signed toward map center at spawn time
## so a corner start never spawns units off the map. Hive has no mobile start
## (its stronghold mines and trains); the Rebels open with workers + a guard.
const LOADOUTS := {
	"hive": {
		"main": "hive.stronghold",
		"units": [],
	},
	"rebels": {
		"main": "rebels.headquarters",
		"units": [
			{ "type": "rebels.worker", "ox": 4, "oy": 6 },
			{ "type": "rebels.worker", "ox": 6, "oy": 4 },
			{ "type": "rebels.worker", "ox": 6, "oy": 6 },
			{ "type": "rebels.gunner", "ox": 5, "oy": 5 },
		],
	},
}


## The factions the map declares by default (pid -> faction), used to seed the
## faction-select screen and by headless tests that want the canonical matchup.
static func default_factions(map: MapData) -> Dictionary:
	var out := {}
	for p: Dictionary in map.players:
		out[int(p["id"])] = str(p["faction"])
	return out


## All faction ids that have a loadout, sorted — the pickable sides.
static func playable_factions() -> Array:
	var out := LOADOUTS.keys()
	out.sort()
	return out


## Rewrite `map` in place so each player fields `factions[pid]` (falling back
## to the map's declared faction). Neutral resources (player 0) are kept; any
## prior player loadout is cleared and respawned from the start anchors.
static func apply(map: MapData, factions: Dictionary) -> void:
	# Player faction assignments.
	for p: Dictionary in map.players:
		var pid := int(p["id"])
		if factions.has(pid):
			p["faction"] = str(factions[pid])

	# Drop any player-owned spawns; keep neutral map resources.
	var kept: Array[Dictionary] = []
	for o: Dictionary in map.objects:
		if int(o.get("player", 0)) == 0:
			kept.append(o)
	map.objects = kept

	# Spawn each player's loadout at their anchor, in player-id order so entity
	# id assignment is stable regardless of how the screen ordered the picks.
	var starts := map.starts.duplicate()
	starts.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return int(a["player"]) < int(b["player"]))
	for s: Dictionary in starts:
		var pid := int(s["player"])
		var faction := str(factions.get(pid, _faction_of(map, pid)))
		if not LOADOUTS.has(faction):
			map.errors.append("no loadout for faction '%s'" % faction)
			continue
		_spawn_loadout(map, pid, faction, int(s["cx"]), int(s["cy"]))

	map.rehash()


static func _faction_of(map: MapData, pid: int) -> String:
	for p: Dictionary in map.players:
		if int(p["id"]) == pid:
			return str(p["faction"])
	return ""


static func _spawn_loadout(map: MapData, pid: int, faction: String,
		cx: int, cy: int) -> void:
	var load: Dictionary = LOADOUTS[faction]
	var main_key := map.catalog.key_of(str(load["main"]))
	if main_key == -1:
		map.errors.append("loadout main '%s' missing from catalog" % load["main"])
		return
	map.objects.append({
		"type_key": main_key, "type": str(load["main"]), "player": pid,
		"cx": cx, "cy": cy, "completed": true,
	})

	# Anchor tile and the direction that points toward the map center, so
	# offsets always land on-map and face the fight.
	var anchor_tx := cx / SimGrid.PATH_SUBDIV
	var anchor_ty := cy / SimGrid.PATH_SUBDIV
	var dirx := 1 if anchor_tx < map.tiles_w / 2 else -1
	var diry := 1 if anchor_ty < map.tiles_h / 2 else -1
	for u: Dictionary in load["units"]:
		var ukey := map.catalog.key_of(str(u["type"]))
		if ukey == -1:
			map.errors.append("loadout unit '%s' missing from catalog" % u["type"])
			continue
		var tx := anchor_tx + dirx * int(u["ox"])
		var ty := anchor_ty + diry * int(u["oy"])
		map.objects.append({
			"type_key": ukey, "type": str(u["type"]), "player": pid,
			"x": Fixed.from_int(tx), "y": Fixed.from_int(ty),
		})
