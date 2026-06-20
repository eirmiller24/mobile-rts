class_name MapBundle
## Bundle export (design_m5.md §4.1, §7 bundle_loader_check round-trip). Packs a
## bundle directory into a distributable `.zip`, stamping the manifest's
## `content_hash` with the compiled bundle's hash so import can detect tampering.
## The inverse of MapLoader.load_bundle_zip — together they round-trip losslessly.
##
## Everything here is outside the determinism wall (load-time tooling).


## Pack `src_dir` (a bundle folder) into `out_zip`, writing every bundle file and
## replacing manifest.json with a copy whose `content_hash` is the loaded bundle's
## hash. Returns the (possibly empty) error list; non-empty means nothing usable
## was written.
static func export_zip(src_dir: String, out_zip: String) -> PackedStringArray:
	var errors := PackedStringArray()
	var base := src_dir if src_dir.ends_with("/") else src_dir + "/"

	# Compile the bundle to learn its content hash (also validates it up front).
	var map := MapLoader.load_bundle_dir(src_dir)
	if not map.ok():
		errors.append("cannot export an invalid bundle:")
		errors.append_array(map.errors)
		return errors

	var rel_paths := _list_files(base, "")
	if not rel_paths.has("manifest.json"):
		errors.append("bundle has no manifest.json")
		return errors

	var packer := ZIPPacker.new()
	if packer.open(out_zip) != OK:
		errors.append("cannot create zip %s" % out_zip)
		return errors

	for rel: String in rel_paths:
		var bytes: PackedByteArray
		if rel == "manifest.json":
			bytes = _stamp_manifest(base + rel, map.hash_value, errors)
		else:
			bytes = FileAccess.get_file_as_bytes(base + rel)
		packer.start_file(rel)
		packer.write_file(bytes)
		packer.close_file()
	packer.close()
	return errors


## Read manifest.json, set content_hash, return the re-serialized bytes.
static func _stamp_manifest(path: String, content_hash: int, errors: PackedStringArray) -> PackedByteArray:
	var text := FileAccess.get_file_as_string(path)
	var data: Variant = JSON.parse_string(text)
	if typeof(data) != TYPE_DICTIONARY:
		errors.append("manifest.json is not a JSON object")
		return text.to_utf8_buffer()
	(data as Dictionary)["content_hash"] = content_hash
	return JSON.stringify(data, "\t").to_utf8_buffer()


## Bundle-relative file paths under `dir`, recursing into subdirectories (so the
## catalog/ layer files ride along). `prefix` is the accumulated relative path.
static func _list_files(dir: String, prefix: String) -> PackedStringArray:
	var out := PackedStringArray()
	var d := DirAccess.open(dir)
	if d == null:
		return out
	for f: String in d.get_files():
		out.append(prefix + f)
	for sub: String in d.get_directories():
		out.append_array(_list_files(dir + sub + "/", prefix + sub + "/"))
	return out
