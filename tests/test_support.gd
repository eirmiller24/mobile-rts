class_name TestSupport
## Shared fixtures for the headless checks: a small synthetic catalog
## (stats matching the M2-era defaults so the movement/combat scenarios
## keep their character) and a blank map. Tests that need the shipped
## content compile the real data files instead.

const GRUNT := "t.grunt"
const CRITTER := "t.critter"
const WALL := "t.wall"
const ROCK := "t.rock"


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
	}


static func catalog() -> CompiledCatalog:
	var cat := CatalogCompiler.compile([layer()])
	assert(cat.ok(), "test catalog failed to compile: %s" % [cat.errors])
	return cat


## Sim over a blank map with the synthetic catalog — the common fixture.
static func sim(seed_value: int, tiles_w: int, tiles_h: int) -> Sim:
	return Sim.new(seed_value, catalog(), MapData.blank(tiles_w, tiles_h))
