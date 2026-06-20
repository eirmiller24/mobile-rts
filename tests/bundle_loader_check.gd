extends SceneTree
## The map-bundle loader (design_m5.md §4, §7 bundle_loader_check). A bundle
## directory (manifest + objects + regions + triggers.lua) loads into a complete,
## playable MapData: catalog compiled, regions interned, triggers compiled. The
## compiler refuses a bad script loudly; a tampered content hash fails at load;
## the M3/M4 single-file maps still load; and a `.zip` bundle round-trips. The
## loaded triggers then actually run in the native sim.
##
## Native-sim assertions skip cleanly if the extension is not built; the pure
## loader assertions always run.
##
## Run:
##   godot --headless --path . -s res://tests/bundle_loader_check.gd

var failures := 0
const ROOT := "user://test_bundle"
const ZIP := "user://test_bundle.zip"


func _initialize() -> void:
	_test_dir_bundle()
	_test_content_hash()
	_test_bad_triggers()
	_test_single_file_still_loads()
	_test_zip_bundle()
	_test_export_roundtrip()

	if failures == 0:
		print("bundle_loader_check: OK")
		quit(0)
	else:
		print("bundle_loader_check: FAILED (%d)" % failures)
		quit(1)


func _fail(msg: String) -> void:
	push_error(msg)
	print("  FAIL: ", msg)
	failures += 1


func _write(path: String, text: String) -> void:
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(text)
	f.close()


# Build a self-contained bundle dir with a bundle-relative test catalog.
func _build_bundle(triggers_src: String, content_hash: Variant = null) -> void:
	DirAccess.make_dir_recursive_absolute(ROOT + "/catalog")
	_write(ROOT + "/catalog/test.json", JSON.stringify(TestSupport.layer()))
	var manifest := {
		"name": "Test Bundle",
		"version": 1,
		"catalog_layers": ["catalog/test.json"],
		"terrain": {"tiles_w": 48, "tiles_h": 48},
		"players": [
			{"id": 1, "faction": "test", "start_alloy": 500, "start_flux": 500},
			{"id": 2, "faction": "test", "start_alloy": 500, "start_flux": 500},
		],
	}
	if content_hash != null:
		manifest["content_hash"] = content_hash
	_write(ROOT + "/manifest.json", JSON.stringify(manifest))
	# Regions in pathing cells: zone covers world (7..9) -> cells (14,14)+(4,4).
	_write(ROOT + "/objects.json", JSON.stringify({
		"objects": [],
		"regions": [{"name": "zone", "cx": 14, "cy": 14, "w": 4, "h": 4}],
	}))
	_write(ROOT + "/triggers.lua", triggers_src)


const GOOD_TRIGGERS := """
on match_start
	set_resource(PLAYER_1, ALLOY, 1234)
	create_unit(t.grunt, PLAYER_1, point(2, 2))
end

on every(1)
	local g: group = units_of_player(PLAYER_1, OF_TYPE(t.grunt))
	for u in g do
		set_unit_position(u, point(8, 8))
	end
end

on unit_enters_region(zone)
	add_resource(PLAYER_1, FLUX, 25)
end
"""


# --- A full bundle dir loads and its triggers run in the native sim. ---
func _test_dir_bundle() -> void:
	_build_bundle(GOOD_TRIGGERS)
	var map := MapLoader.load_path(ROOT)
	if not map.ok():
		_fail("bundle failed to load: %s" % str(map.errors))
		return
	if map.regions.size() != 1 or not map.region_names.has("zone"):
		_fail("bundle regions not parsed: %s" % str(map.regions))
	if map.trigger_program == null or not map.trigger_program.ok():
		_fail("bundle triggers not compiled")
		return
	if map.trigger_program.events.size() / TriggerIR.EVENT_STRIDE != 3:
		_fail("expected 3 trigger events from the bundle")

	if not ClassDB.class_exists("NativeSim"):
		print("  (native sim not built — skipping bundle runtime assertions)")
		return
	var nat: Object = ClassDB.instantiate("NativeSim")
	nat.construct(0xC0FFEE, map.catalog, map)
	nat.load_triggers(map.trigger_program)
	for i in 5:
		nat.step()
	var res: Dictionary = nat.resources_of(1)
	if int(res.get("alloy", -1)) != 1234:
		_fail("bundle match_start set_resource failed: alloy=%s" % str(res.get("alloy")))
	if int(res.get("flux", -1)) != 525:
		_fail("bundle region enter failed: flux=%s (want 525)" % str(res.get("flux")))


# --- A correct content hash loads; a tampered one fails at load (§4.1). ---
func _test_content_hash() -> void:
	_build_bundle(GOOD_TRIGGERS)
	var probe := MapLoader.load_path(ROOT)
	if not probe.ok():
		_fail("content-hash probe load failed: %s" % str(probe.errors))
		return
	var good := probe.hash_value

	_build_bundle(GOOD_TRIGGERS, good)
	var ok_map := MapLoader.load_path(ROOT)
	if not ok_map.ok():
		_fail("bundle with correct content_hash rejected: %s" % str(ok_map.errors))

	_build_bundle(GOOD_TRIGGERS, good + 1)
	var bad := MapLoader.load_path(ROOT)
	if bad.ok():
		_fail("tampered content_hash was not rejected")


# --- A bundle with a broken script fails to load, with a clear error. ---
func _test_bad_triggers() -> void:
	_build_bundle("on match_start\n  no_such_function()\nend")
	var map := MapLoader.load_path(ROOT)
	if map.ok():
		_fail("bundle with a bad trigger script loaded anyway")
	var saw := false
	for e in map.errors:
		if String(e).contains("triggers:"):
			saw = true
	if not saw:
		_fail("bad-trigger error not surfaced: %s" % str(map.errors))


# --- The M3/M4 single-file maps still load through the same entry point. ---
func _test_single_file_still_loads() -> void:
	var map := MapLoader.load_path("res://maps/dev_arena.json")
	if not map.ok():
		_fail("single-file map regressed: %s" % str(map.errors))
	if map.trigger_program != null:
		_fail("single-file map should have no trigger program")


# --- export(dir) -> .zip -> import round-trips losslessly, hash stable (§4.1). ---
func _test_export_roundtrip() -> void:
	var src := "res://maps/td_maze"
	var src_map := MapLoader.load_path(src)
	if not src_map.ok():
		_fail("export source bundle invalid: %s" % str(src_map.errors))
		return
	var out := "user://td_export.zip"
	var errs := MapBundle.export_zip(src, out)
	if not errs.is_empty():
		_fail("export failed: %s" % str(errs))
		return
	var reimported := MapLoader.load_path(out)
	if not reimported.ok():
		_fail("re-imported zip invalid: %s" % str(reimported.errors))
		return
	# Lossless: the round-tripped content hash equals the source's, and the
	# exporter stamped that hash into the manifest (so a later edit is caught).
	if reimported.hash_value != src_map.hash_value:
		_fail("export round-trip changed the content hash: %d -> %d"
				% [src_map.hash_value, reimported.hash_value])
	if reimported.trigger_program == null or not reimported.trigger_program.ok():
		_fail("round-tripped bundle lost its triggers")
	if reimported.regions.size() != src_map.regions.size():
		_fail("round-tripped bundle lost regions")


# --- A .zip bundle round-trips through ZIPReader (local import). ---
func _test_zip_bundle() -> void:
	var manifest := {
		"name": "Zip Bundle", "version": 1,
		"catalog_layers": ["res://data/catalog/core.json", "res://data/catalog/hive.json"],
		"terrain": {"tiles_w": 48, "tiles_h": 48},
		"players": [{"id": 1, "faction": "hive", "start_alloy": 100, "start_flux": 100}],
	}
	var packer := ZIPPacker.new()
	if packer.open(ZIP) != OK:
		_fail("could not create zip bundle")
		return
	packer.start_file("manifest.json")
	packer.write_file(JSON.stringify(manifest).to_utf8_buffer())
	packer.close_file()
	packer.start_file("triggers.lua")
	packer.write_file("on match_start\n  set_resource(PLAYER_1, ALLOY, 999)\nend".to_utf8_buffer())
	packer.close_file()
	packer.close()

	var map := MapLoader.load_path(ZIP)
	if not map.ok():
		_fail("zip bundle failed to load: %s" % str(map.errors))
		return
	if map.trigger_program == null or not map.trigger_program.ok():
		_fail("zip bundle triggers not compiled")
		return
	if not ClassDB.class_exists("NativeSim"):
		return
	var nat: Object = ClassDB.instantiate("NativeSim")
	nat.construct(1, map.catalog, map)
	nat.load_triggers(map.trigger_program)
	nat.step()
	var res: Dictionary = nat.resources_of(1)
	if int(res.get("alloy", -1)) != 999:
		_fail("zip bundle trigger did not run: alloy=%s" % str(res.get("alloy")))
