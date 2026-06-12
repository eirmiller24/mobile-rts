class_name CatalogSchema
## Declares every legal `sim` field per catalog kind: type, default, and
## constraints (design_m3.md §2.3/§2.5). The compiler validates authored
## JSON against these tables; unknown `sim` fields are a compile error,
## `view`/`ui` sections are open dictionaries.
##
## Field types and their compiled forms:
##   int          JSON integer            -> int
##   fixed        decimal string "2.5"    -> 16.16 Fixed int
##   seconds      decimal string "1.5"    -> ticks (int, x20); must land on
##                                           a whole tick or compile fails
##   bool         JSON bool               -> bool
##   enum         string                  -> int (index into "values")
##   attack_class / armor_class           -> int (index into the classes
##                string                     entry's lists; "" = -1 unset)
##   id_list      array of entry ids      -> PackedInt32Array of type_keys
##                                           (entries must be of "kind")
##   flags        array of strings        -> PackedStringArray (aura marker
##                                           flags; engine reads "territory")
##   modifiers    dict                    -> dict, keys from MODIFIERS
##   stat_overrides dict                  -> dict, keys from UNIT (scalar
##                                           fields only; morphed form)
##   string_list  array of strings        -> PackedStringArray
##   matrix       dict of dicts of fixed  -> flat PackedInt64Array indexed
##                                           [attack * n_armor + armor]

const KINDS := ["unit", "structure", "resource", "ability", "classes"]

## Aura modifier keys: declared type plus which direction is "best" when
## overlapping auras supply the same key (design_m3.md §2.5).
const MODIFIERS := {
	"hp_regen": {"type": "fixed", "best": "max"},      # hp/sec
	"damage_taken": {"type": "fixed", "best": "min"},  # incoming multiplier
}

const UNIT := {
	"hp": {"type": "int", "default": 1, "min": 1},
	"damage": {"type": "int", "default": 0, "min": 0},
	"radius": {"type": "fixed", "default": "0.4"},
	"speed": {"type": "fixed", "default": "0"},
	"attack_range": {"type": "fixed", "default": "0"},
	"acquire_range": {"type": "fixed", "default": "0"},
	"cooldown": {"type": "seconds", "default": "1.0"},
	"crit_base": {"type": "fixed", "default": "0"},
	"crit_bonus": {"type": "fixed", "default": "0"},
	"sight": {"type": "fixed", "default": "0"},
	"hits_air": {"type": "bool", "default": false},
	"attack_class": {"type": "attack_class", "default": ""},
	"armor_class": {"type": "armor_class", "default": ""},
	"bandwidth": {"type": "int", "default": 0, "min": 0},
	"cost_alloy": {"type": "int", "default": 0, "min": 0},
	"cost_flux": {"type": "int", "default": 0, "min": 0},
	"train_time": {"type": "seconds", "default": "1.0"},
	"abilities": {"type": "id_list", "kind": "ability", "default": []},
}

const STRUCTURE := {
	"hp": {"type": "int", "default": 1, "min": 1},
	"foot_w": {"type": "int", "default": 2, "min": 1},
	"foot_h": {"type": "int", "default": 2, "min": 1},
	"armor_class": {"type": "armor_class", "default": ""},
	"damage": {"type": "int", "default": 0, "min": 0},
	"attack_range": {"type": "fixed", "default": "0"},
	"acquire_range": {"type": "fixed", "default": "0"},
	"cooldown": {"type": "seconds", "default": "1.0"},
	"attack_class": {"type": "attack_class", "default": ""},
	"hits_air": {"type": "bool", "default": false},
	"cost_alloy": {"type": "int", "default": 0, "min": 0},
	"cost_flux": {"type": "int", "default": 0, "min": 0},
	"build_time": {"type": "seconds", "default": "1.0"},
	"capsule_cost_alloy": {"type": "int", "default": 0, "min": 0},
	"sight": {"type": "fixed", "default": "0"},
	"damage_taken": {"type": "fixed", "default": "1.0"},
	"bandwidth_provided": {"type": "int", "default": 0, "min": 0},
	"nano_pool": {"type": "int", "default": 0, "min": 0},
	"abilities": {"type": "id_list", "kind": "ability", "default": []},
	"trains": {"type": "id_list", "kind": "unit", "default": []},
	"builds_on_vent": {"type": "bool", "default": false},
	## Can only be ordered inside the owner's territory (so it never
	## flies a capsule). The Siphon authors true: extracting a far vent
	## means extending influence to it first.
	"requires_territory": {"type": "bool", "default": false},
	"dummy": {"type": "bool", "default": false},
	## Where a fresh stronghold's whole nano pool starts (design_m3.md
	## §4.6) — the game must economically function before the player ever
	## opens the console.
	"default_allocation": {"type": "enum",
		"values": ["idle", "alloy", "flux", "assist"], "default": "alloy"},
}

const RESOURCE := {
	"resource": {"type": "enum", "values": ["alloy", "flux"], "required": true},
	"amount": {"type": "int", "default": 0, "min": 0},
	"throughput": {"type": "fixed", "default": "1.0"},
	"foot_w": {"type": "int", "default": 2, "min": 1},
	"foot_h": {"type": "int", "default": 2, "min": 1},
}

const ABILITY := {
	"ability_kind": {"type": "enum",
		"values": ["aura", "toggle_morph", "blink", "build"], "required": true},
	# toggle_morph
	"morph_time": {"type": "seconds", "default": "1.0"},
	"morphed": {"type": "stat_overrides", "default": {}},
	# aura
	"radius": {"type": "fixed", "default": "0"},
	"affects": {"type": "enum", "values": ["own_structures"],
		"default": "own_structures"},
	"flags": {"type": "flags", "default": []},
	"modifiers": {"type": "modifiers", "default": {}},
	# blink
	"range": {"type": "fixed", "default": "0"},
	"travel_time": {"type": "seconds", "default": "1.0"},
	"cooldown_time": {"type": "seconds", "default": "0"},
	# build
	"structures": {"type": "id_list", "kind": "structure", "default": []},
	"mechanic": {"type": "enum", "values": ["capsule", "worker"],
		"default": "capsule"},
}

## The singleton `classes` entry: damage/armor class declarations, the
## damage multiplier matrix, and global sim constants (design_m3.md §2.5,
## §4.5, §4.6).
const CLASSES := {
	"attack_classes": {"type": "string_list", "required": true},
	"armor_classes": {"type": "string_list", "required": true},
	"matrix": {"type": "matrix", "required": true},
	"capsule_time": {"type": "seconds", "default": "3.0"},
	"capsule_hp": {"type": "int", "default": 80, "min": 1},
	"alloy_rate": {"type": "fixed", "default": "0.1"},   # /sec per nano
	"flux_rate": {"type": "fixed", "default": "0.05"},   # /sec per nano
	"assist_rate": {"type": "fixed", "default": "0.5"},  # progress ticks/tick per nano
	"repair_rate": {"type": "fixed", "default": "1.0"},  # hp/sec per nano
}

## Compiled enum value sets the sim references by name (kept here so sim
## code never compares strings).
enum AbilityKind { AURA, TOGGLE_MORPH, BLINK, BUILD }
enum ResourceKind { ALLOY, FLUX }
enum BuildMechanic { CAPSULE, WORKER }
enum Affects { OWN_STRUCTURES }
enum Allocation { IDLE, ALLOY, FLUX, ASSIST }


static func fields_for(kind: String) -> Dictionary:
	match kind:
		"unit": return UNIT
		"structure": return STRUCTURE
		"resource": return RESOURCE
		"ability": return ABILITY
		"classes": return CLASSES
	return {}
