class_name TestSupport
## Shared fixtures for the headless checks: a small synthetic catalog
## (stats matching the M2-era defaults so the movement/combat scenarios
## keep their character) and a blank map. Tests that need the shipped
## content compile the real data files instead.

const GRUNT := "t.grunt"
const CRITTER := "t.critter"
const WALL := "t.wall"
const ROCK := "t.rock"
const HUB := "t.hub"
const NODE := "t.node"
const WORKER := "t.worker"
const DEPOT := "t.depot"


static func layer() -> Dictionary:
	return {
		"core.classes": {
			"kind": "classes",
			"sim": {
				"attack_classes": ["claw"],
				"armor_classes": ["light", "structure"],
				"matrix": {
					"claw": { "light": "1.0", "structure": "1.0" }
				}
			}
		},
		GRUNT: {
			"kind": "unit",
			"sim": {
				"hp": 100, "damage": 10, "attack_class": "claw",
				"armor_class": "light", "radius": "0.4", "speed": "3.0",
				"attack_range": "1.5", "acquire_range": "6.0",
				"cooldown": "1.0", "sight": "7.0"
			}
		},
		CRITTER: {
			"extends": GRUNT,
			"sim": { "crit_base": "0.25", "crit_bonus": "0.25" }
		},
		WALL: {
			"kind": "structure",
			"sim": { "hp": 150, "foot_w": 1, "foot_h": 1,
				"armor_class": "structure", "build_time": "1.0" }
		},
		# Untargetable scenery blocker (a zero-amount resource node).
		ROCK: {
			"kind": "resource",
			"sim": { "resource": "alloy", "amount": 0, "foot_w": 3, "foot_h": 3 }
		},
		# Economy fixtures (used by the perf check's running economy).
		"t.field": {
			"kind": "ability",
			"sim": {
				"ability_kind": "aura", "radius": "10.0",
				"affects": "own_structures", "flags": ["territory"],
				"modifiers": { "hp_regen": "2.0", "damage_taken": "1.0" }
			}
		},
		HUB: {
			"kind": "structure",
			"sim": {
				"hp": 1000, "foot_w": 4, "foot_h": 4, "armor_class": "structure",
				"build_time": "5.0", "sight": "12.0",
				"bandwidth_provided": 99, "nano_pool": 30,
				"abilities": ["t.field"], "trains": [GRUNT]
			}
		},
		NODE: {
			"kind": "resource",
			"sim": { "resource": "alloy", "amount": 100000, "throughput": "5.0",
				"foot_w": 2, "foot_h": 2 }
		},
		# M4 worker-fleet fixtures (the perf check's second, Rebel economy).
		WORKER: {
			"kind": "unit",
			"sim": {
				"hp": 60, "armor_class": "light", "radius": "0.4", "speed": "3.0",
				"sight": "7.0", "carry_capacity": 10, "harvest_rate": "2.0"
			}
		},
		DEPOT: {
			"kind": "structure",
			"sim": {
				"hp": 800, "foot_w": 4, "foot_h": 4, "armor_class": "structure",
				"build_time": "1.0", "sight": "10.0", "is_depot": true
			}
		},
	}


static func catalog() -> CompiledCatalog:
	var cat := CatalogCompiler.compile([layer()])
	assert(cat.ok(), "test catalog failed to compile: %s" % [cat.errors])
	return cat


## Sim over a blank map with the synthetic catalog — the common fixture.
## `player_ids` adds funded SimPlayers (needed for economy/build/train).
static func sim(seed_value: int, tiles_w: int, tiles_h: int,
		player_ids: Array = []) -> Sim:
	var map := MapData.blank(tiles_w, tiles_h)
	for pid: int in player_ids:
		map.players.append({"id": pid, "faction": "test",
				"start_alloy": 100000, "start_flux": 100000})
	map.rehash()
	return Sim.new(seed_value, catalog(), map)
