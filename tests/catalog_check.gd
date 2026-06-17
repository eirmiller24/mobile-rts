extends SceneTree
## Headless checks for the object catalog (design_m3.md §2 / §8):
## Fixed.from_decimal exactness, schema validation errors, extends merge
## correctness (the relay aura deriving from hive.influence is the live
## case), layer overrides, and catalog hash stability incl. a golden hash
## that catches accidental schema drift.
##
## Run on the host (Godot is not installed in the devcontainer):
##   flatpak run org.godotengine.Godot --headless --path . \
##     -s res://tests/catalog_check.gd

## SimHash of the synthetic catalog in _hash_layer(). If this changes, the
## compiled representation changed: bump deliberately, never casually —
## peers with different compiled forms desync at tick 0.
const GOLDEN_HASH := 0xC4F85900

var failures := 0


func _initialize() -> void:
	_check_from_decimal()
	_check_real_catalog()
	_check_rebels_catalog()
	_check_errors()
	_check_layers_and_hash()

	if failures == 0:
		print("catalog_check: OK")
		quit(0)
	else:
		print("catalog_check: FAILED (%d failures)" % failures)
		quit(1)


func _fail(msg: String) -> void:
	push_error(msg)
	failures += 1


func _expect(cond: bool, msg: String) -> void:
	if not cond:
		_fail(msg)


# --- Fixed.from_decimal -------------------------------------------------------


func _check_from_decimal() -> void:
	var golden := {
		"0": 0,
		"1": Fixed.ONE,
		"2.5": Fixed.ONE * 5 / 2,
		"-0.25": -(Fixed.ONE / 4),
		"12.375": 811008,        # exact: 12.375 * 65536
		"0.05": 3277,            # 3276.8 rounds half-up to 3277
		"0.1": 6554,             # 6553.6 -> 6554
		"0.7": 45875,            # 45875.2 -> 45875
		"3.0": 3 * Fixed.ONE,
		"-12": -12 * Fixed.ONE,
		".5": Fixed.HALF,
		"0.999999": 65536,       # 65535.93 -> 65536 (rounds up to ONE)
		"0.0000076": 0,          # 0.498 raw -> rounds down to 0
	}
	for s: String in golden:
		var got := Fixed.from_decimal(s)
		_expect(got == golden[s],
				"from_decimal(\"%s\") = %d, want %d" % [s, got, golden[s]])


# --- the shipped catalog ------------------------------------------------------


func _check_real_catalog() -> void:
	var cat := CatalogCompiler.compile_paths([
		"res://data/catalog/core.json", "res://data/catalog/hive.json"])
	for e in cat.errors:
		_fail("real catalog: %s" % e)
	if not cat.ok():
		return

	# Interning is sorted and stable.
	var sorted_ids := cat.ids.duplicate()
	sorted_ids.sort()
	_expect(cat.ids == sorted_ids, "type_keys are not sorted")
	_expect(cat.key_of("hive.mite") >= 0, "hive.mite missing")

	# The relay aura derives from hive.influence via extends: radius is
	# overridden, flags and modifiers are inherited (design_m3.md §4.3).
	var relay_aura := cat.sim_of(cat.key_of("hive.influence_relay"))
	_expect(relay_aura["radius"] == 6 * Fixed.ONE, "relay aura radius not overridden")
	_expect("territory" in relay_aura["flags"], "relay aura lost the territory flag")
	_expect(relay_aura["modifiers"]["hp_regen"] == 2 * Fixed.ONE,
			"relay aura lost inherited hp_regen")
	_expect(relay_aura["modifiers"]["damage_taken"] == Fixed.ONE,
			"relay aura lost inherited damage_taken")
	_expect(cat.kind_of(cat.key_of("hive.influence_relay")) == "ability",
			"relay aura kind not inherited")

	# Seconds compile to whole ticks; fixed to 16.16.
	var mite := cat.sim_of(cat.key_of("hive.mite"))
	_expect(mite["hp"] == 40, "mite hp")
	_expect(mite["cooldown"] == 16, "mite cooldown ticks (0.8s -> 16)")
	_expect(mite["train_time"] == 160, "mite train_time ticks")
	_expect(mite["speed"] == Fixed.ONE * 7 / 2, "mite speed fixed")

	# Damage class matrix (acid is good vs armored).
	var acid := cat.attack_classes.find("acid")
	var armored := cat.armor_classes.find("armored")
	_expect(cat.class_mul(acid, armored) == Fixed.ONE * 3 / 2, "acid vs armored = 1.5")
	_expect(cat.class_mul(-1, armored) == Fixed.ONE, "unset class multiplies by 1")

	# Flag resolution: both influence auras grant territory.
	_expect(cat.abilities_with_flag("territory").size() == 2,
			"territory flag should resolve to 2 abilities")
	_expect(cat.abilities_with_flag("no_such_flag").is_empty(),
			"unknown flag should resolve to nothing")

	# Globals compiled from core.classes.
	_expect(cat.globals["capsule_time"] == 60, "capsule_time ticks")
	_expect(cat.globals["alloy_rate"] == Fixed.from_decimal("0.1"), "alloy_rate")

	# Roster wiring.
	var stronghold := cat.sim_of(cat.key_of("hive.stronghold"))
	_expect(stronghold["trains"].size() == 4, "stronghold trains 4 units")
	var build := cat.sim_of(cat.key_of("hive.capsule_build"))
	_expect(build["structures"].size() == 3, "capsule_build sells 3 structures")
	_expect(build["mechanic"] == CatalogSchema.BuildMechanic.CAPSULE, "capsule mechanic")
	var carapace_root := cat.sim_of(cat.key_of("hive.root"))
	_expect(carapace_root["morphed"]["damage"] == 25, "rooted damage override")
	_expect(carapace_root["morphed"]["speed"] == 0, "rooted speed override")
	_expect(carapace_root["morphed"]["hits_air"] == true, "rooted hits_air override")


# --- the M4 three-layer (Rebel) catalog ---------------------------------------


func _check_rebels_catalog() -> void:
	var cat := CatalogCompiler.compile_paths([
		"res://data/catalog/core.json", "res://data/catalog/hive.json",
		"res://data/catalog/rebels.json"])
	for e in cat.errors:
		_fail("rebels catalog: %s" % e)
	if not cat.ok():
		return

	# The new construction armor class and its anti-construction column (§4.3).
	var construction := cat.armor_classes.find("construction")
	_expect(construction == 3, "construction armor class should be index 3")
	var acid := cat.attack_classes.find("acid")
	var shock := cat.attack_classes.find("shock")
	_expect(cat.class_mul(acid, construction) == Fixed.ONE * 5 / 2,
			"acid vs construction = 2.5")
	_expect(cat.class_mul(shock, construction) == Fixed.ONE * 7 / 4,
			"shock vs construction = 1.75")

	# Worker harvest/build fields and the worker_build ability.
	var worker := cat.sim_of(cat.key_of("rebels.worker"))
	_expect(worker["carry_capacity"] == 10, "worker carry_capacity")
	_expect(worker["harvest_rate"] == 2 * Fixed.ONE, "worker harvest_rate")
	var wbuild := cat.sim_of(cat.key_of("rebels.worker_build"))
	_expect(wbuild["mechanic"] == CatalogSchema.BuildMechanic.WORKER, "worker build mechanic")
	_expect(wbuild["structures"].size() == 4, "worker_build sells 4 structures")

	# Structure role flags (§7.1, §3, §6.5).
	var hq := cat.sim_of(cat.key_of("rebels.headquarters"))
	_expect(hq["is_depot"] and hq["is_main"], "HQ is depot and main")
	_expect(hq["bandwidth_provided"] == 10, "HQ provides starting Crew")
	# Rebels have NO feral penalty: default damage_taken stays 1.0 (§2.1).
	_expect(hq["damage_taken"] == Fixed.ONE, "Rebel HQ has no feral penalty")
	var refinery := cat.sim_of(cat.key_of("rebels.refinery"))
	_expect(refinery["is_refinery"] and not refinery["is_depot"],
			"Refinery is a source, not a depot")
	var barricade := cat.sim_of(cat.key_of("rebels.barricade"))
	_expect(barricade["los_height"] == 2, "Barricade stands 2 LOS levels")
	_expect(barricade["foot_w"] == 1 and barricade["foot_h"] == 1,
			"Barricade is a 1x1 pathing-cell footprint")

	# Capsule detection and the ground-only Marauder (§2.1, §6.3).
	_expect(cat.sim_of(cat.key_of("rebels.watcher"))["detects_capsules"],
			"Watcher detects capsules")
	_expect(not cat.sim_of(cat.key_of("rebels.marauder"))["hits_air"],
			"Marauder is ground-only")

	# New M4 globals compiled from core.classes.
	_expect(cat.globals["max_builders"] == 3, "max_builders global")
	_expect(cat.globals["build_rate"] == 20 * Fixed.ONE, "build_rate global")
	_expect(cat.globals["refinery_radius"] == 8 * Fixed.ONE, "refinery_radius global")


# --- schema validation errors -------------------------------------------------


## Minimal valid catalog the error cases graft onto.
func _base() -> Dictionary:
	return {
		"core.classes": {
			"kind": "classes",
			"sim": {
				"attack_classes": ["claw"],
				"armor_classes": ["light"],
				"matrix": { "claw": { "light": "1.0" } }
			}
		},
		"t.grunt": { "kind": "unit", "sim": { "hp": 10, "armor_class": "light" } },
	}


func _expect_error(layer_patch: Dictionary, substring: String, what: String) -> void:
	var layer := _base()
	layer.merge(layer_patch, true)
	var cat := CatalogCompiler.compile([layer])
	for e in cat.errors:
		if substring in e:
			return
	_fail("%s: expected an error containing '%s', got %s"
			% [what, substring, cat.errors])


func _check_errors() -> void:
	_expect_error({"t.bad": {"kind": "unit", "sim": {"armor_class": "light", "banana": 1}}},
			"unknown sim field", "unknown field")
	_expect_error({"t.bad": {"kind": "unit", "sim": {"armor_class": "light", "hp": "ten"}}},
			"expected an integer", "bad int")
	_expect_error({"t.bad": {"kind": "unit", "sim": {"armor_class": "light", "speed": 2.5}}},
			"decimal strings", "fixed as JSON number")
	_expect_error({"t.bad": {"kind": "unit", "sim": {"armor_class": "light", "cooldown": "1.03"}}},
			"whole number of ticks", "off-tick seconds")
	_expect_error({
			"t.a": {"extends": "t.b"},
			"t.b": {"extends": "t.a"}},
			"extends cycle", "cycle")
	_expect_error({"t.bad": {"kind": "structure", "extends": "t.grunt"}},
			"cannot change kind", "kind change")
	_expect_error({"t.bad": {"extends": "t.nowhere"}},
			"extends unknown entry", "unknown base")
	_expect_error({"t.bad": {"kind": "ability", "sim": {
			"ability_kind": "aura", "radius": "2.0",
			"modifiers": {"speed_boost": "1.0"}}}},
			"unknown modifier", "unknown aura modifier")
	_expect_error({"t.bad": {"kind": "unit", "sim": {"hp": 5}}},
			"needs an armor_class", "missing armor class")
	_expect_error({"t.bad": {"kind": "ability", "sim": {
			"ability_kind": "toggle_morph",
			"morphed": {"abilities": []}}}},
			"cannot override", "morphed overriding id_list")
	_expect_error({"t.bad": {"kind": "structure", "sim": {
			"armor_class": "light", "trains": ["t.nowhere"]}}},
			"unknown entry", "id_list to unknown entry")
	_expect_error({"t.bad": {"kind": "structure", "sim": {
			"armor_class": "light", "trains": ["core.classes"]}}},
			"is not a unit", "id_list kind mismatch")
	_expect_error({"t.bad": {"kind": "ability", "sim": {}}},
			"missing required field", "ability without ability_kind")
	_expect_error({"t.bad": {"kind": "banana", "sim": {}}},
			"unknown kind", "unknown kind")

	# Exactly one classes entry.
	var no_classes := _base()
	no_classes.erase("core.classes")
	var cat := CatalogCompiler.compile([no_classes])
	_expect(not cat.ok(), "missing classes entry must fail")


# --- layers and hashing -------------------------------------------------------


func _hash_layer() -> Dictionary:
	var layer := _base()
	layer["t.vet"] = {"extends": "t.grunt", "sim": {"hp": 60},
			"view": {"shape": "box"}}
	return layer


func _check_layers_and_hash() -> void:
	# A later layer patches per leaf key and adds entries.
	var patch := {
		"t.grunt": {"sim": {"hp": 99}},
		"t.extra": {"kind": "unit", "sim": {"hp": 1, "armor_class": "light"}},
	}
	var layered := CatalogCompiler.compile([_base(), patch])
	_expect(layered.ok(), "layered compile failed: %s" % [layered.errors])
	if layered.ok():
		_expect(layered.sim_of(layered.key_of("t.grunt"))["hp"] == 99,
				"layer patch did not override hp")
		_expect(layered.key_of("t.extra") >= 0, "layer did not add entry")

	var a := CatalogCompiler.compile([_hash_layer()])
	var b := CatalogCompiler.compile([_hash_layer()])
	_expect(a.ok() and b.ok(), "hash layer compile failed: %s" % [a.errors])
	if not (a.ok() and b.ok()):
		return
	_expect(a.hash_value == b.hash_value, "same catalog hashed differently")
	_expect(a.hash_value == GOLDEN_HASH,
			"catalog hash drifted: got 0x%X, golden 0x%X — the compiled representation changed; if deliberate, update GOLDEN_HASH"
			% [a.hash_value, GOLDEN_HASH])

	# view/ui changes never touch the hash; sim changes always do (§2.2).
	var view_change := _hash_layer()
	view_change["t.vet"]["view"] = {"shape": "cylinder", "color": "ff0000"}
	var c := CatalogCompiler.compile([view_change])
	_expect(c.hash_value == a.hash_value, "view change altered the catalog hash")

	var sim_change := _hash_layer()
	sim_change["t.vet"]["sim"]["hp"] = 61
	var d := CatalogCompiler.compile([sim_change])
	_expect(d.hash_value != a.hash_value, "sim change did not alter the catalog hash")

	# Authoring order is irrelevant: interning sorts.
	var reordered := {}
	var src := _hash_layer()
	var keys := src.keys()
	keys.reverse()
	for k: String in keys:
		reordered[k] = src[k]
	var e := CatalogCompiler.compile([reordered])
	_expect(e.hash_value == a.hash_value, "entry order altered the catalog hash")
