class_name MapLoader
## Parses a map file (design_m3.md §3) into MapData: reads the manifest,
## compiles the declared catalog layers, validates and normalizes the
## object list, and hashes the parsed content. All problems are collected
## on the result, never thrown.


## Load a map from any supported form (design_m5.md §4.1): a single JSON file
## (the M3/M4 degenerate case), a bundle directory, or a `.zip` bundle. The
## bundle is the superset — same compiled MapData, plus regions and a compiled
## trigger program.
static func load_path(path: String) -> MapData:
	var map := MapData.new()
	if path.to_lower().ends_with(".zip"):
		return load_bundle_zip(path, map)
	if DirAccess.dir_exists_absolute(path):
		return load_bundle_dir(path, map)
	var text := FileAccess.get_file_as_string(path)
	if text.is_empty():
		map.errors.append("cannot read map %s" % path)
		return map
	var data: Variant = JSON.parse_string(text)
	if typeof(data) != TYPE_DICTIONARY:
		map.errors.append("map %s is not a JSON object" % path)
		return map
	return load_dict(data, map)


## A bundle on disk (design_m5.md §4.1): a folder with manifest.json, an optional
## objects.json (objects + regions), an optional triggers.lua, and an optional
## catalog/ override layer directory. Read into a self-contained file map so the
## same assembly serves directories and zips.
static func load_bundle_dir(dir_path: String, map: MapData = null) -> MapData:
	if map == null:
		map = MapData.new()
	var base := dir_path if dir_path.ends_with("/") else dir_path + "/"
	var files := {}
	for name: String in ["manifest.json", "objects.json", "triggers.lua"]:
		if FileAccess.file_exists(base + name):
			files[name] = FileAccess.get_file_as_string(base + name)
	var cat_dir := base + "catalog"
	if DirAccess.dir_exists_absolute(cat_dir):
		var d := DirAccess.open(cat_dir)
		if d != null:
			for f: String in d.get_files():
				files["catalog/" + f] = FileAccess.get_file_as_string(cat_dir + "/" + f)
	return _load_bundle(files, map)


## A bundle distributed as a `.zip` (design_m5.md §4.1, local import/export). The
## whole bundle — including its catalog/ — is read from the archive, so a zip
## bundle is fully self-contained.
static func load_bundle_zip(zip_path: String, map: MapData = null) -> MapData:
	if map == null:
		map = MapData.new()
	var z := ZIPReader.new()
	if z.open(zip_path) != OK:
		map.errors.append("cannot open zip bundle %s" % zip_path)
		return map
	var files := {}
	for name: String in z.get_files():
		files[name] = z.read_file(name).get_string_from_utf8()
	z.close()
	return _load_bundle(files, map)


## Shared bundle assembly from an in-memory file map (relative path -> text).
## Compiles the catalog in-memory (so bundle-relative layers work in a zip too),
## parses terrain/players/starts/objects/regions, compiles triggers.lua, hashes,
## and verifies the manifest content hash.
static func _load_bundle(files: Dictionary, map: MapData) -> MapData:
	if not files.has("manifest.json"):
		map.errors.append("bundle has no manifest.json")
		return map
	var manifest: Variant = JSON.parse_string(files["manifest.json"])
	if typeof(manifest) != TYPE_DICTIONARY:
		map.errors.append("manifest.json is not a JSON object")
		return map

	var meta := manifest as Dictionary
	map.name = meta.get("manifest", {}).get("name", meta.get("name", ""))
	map.version = int(meta.get("version", 1))

	# Catalog: resolve each layer to its parsed dict (res:// from disk, otherwise
	# from the bundle's own files) and compile in-memory.
	var layer_dicts: Array[Dictionary] = []
	for layer: Variant in meta.get("catalog_layers", []):
		var lp := str(layer)
		var text := ""
		if lp.begins_with("res://") or lp.begins_with("user://"):
			text = FileAccess.get_file_as_string(lp)
		elif files.has(lp):
			text = files[lp]
		else:
			map.errors.append("catalog layer '%s' not found in bundle" % lp)
			continue
		var ld: Variant = JSON.parse_string(text)
		if typeof(ld) != TYPE_DICTIONARY:
			map.errors.append("catalog layer '%s' is not a JSON object" % lp)
		else:
			layer_dicts.append(ld)
	if layer_dicts.is_empty():
		map.errors.append("bundle declares no catalog_layers")
		return map
	map.catalog = CatalogCompiler.compile(layer_dicts)
	for e in map.catalog.errors:
		map.errors.append("catalog: %s" % e)

	_parse_terrain(meta, map)
	_parse_players(meta, map)
	_parse_starts(meta, map)

	# Objects come from the manifest and/or objects.json; regions likewise.
	var objects_raw: Array = (meta.get("objects", []) as Array).duplicate()
	var regions_raw: Array = meta.get("regions", [])
	if files.has("objects.json"):
		var od: Variant = JSON.parse_string(files["objects.json"])
		if typeof(od) != TYPE_DICTIONARY:
			map.errors.append("objects.json is not a JSON object")
		else:
			objects_raw.append_array((od as Dictionary).get("objects", []))
			regions_raw = (od as Dictionary).get("regions", regions_raw)

	if map.catalog.ok():
		for raw: Variant in objects_raw:
			_normalize_object(raw, map)
		_parse_regions(regions_raw, map)
		if files.has("triggers.lua"):
			map.trigger_program = TriggerCompiler.compile(
					files["triggers.lua"], map.catalog, map.region_names)
			for e in map.trigger_program.errors:
				map.errors.append("triggers: %s" % e)

	map.rehash()
	if meta.has("content_hash"):
		var declared := int(meta["content_hash"])
		if declared != map.hash_value:
			map.errors.append(
					"content hash mismatch (tampered bundle): manifest %d, computed %d"
					% [declared, map.hash_value])
	return map


## Regions are authored in pathing cells {name, cx, cy, w, h}; the sim stores
## fixed-point world rectangles. Ids are assigned ascending (1..) in authored
## order, and the name->id map feeds the trigger compiler.
static func _parse_regions(raw: Array, map: MapData) -> void:
	for entry: Variant in raw:
		if typeof(entry) != TYPE_DICTIONARY:
			map.errors.append("region entry is not an object")
			continue
		var r: Dictionary = entry
		var name := str(r.get("name", ""))
		if name.is_empty():
			map.errors.append("region has no name")
			continue
		if map.region_names.has(name):
			map.errors.append("duplicate region name '%s'" % name)
			continue
		var cx := int(r.get("cx", 0))
		var cy := int(r.get("cy", 0))
		var w := int(r.get("w", 0))
		var h := int(r.get("h", 0))
		if w <= 0 or h <= 0:
			map.errors.append("region '%s' has non-positive size" % name)
			continue
		var rid := map.regions.size() + 1
		map.region_names[name] = rid
		map.regions.append({
			"id": rid,
			"min_x": cx * SimGrid.CELL,
			"min_y": cy * SimGrid.CELL,
			"max_x": (cx + w) * SimGrid.CELL,
			"max_y": (cy + h) * SimGrid.CELL,
		})


static func load_dict(data: Dictionary, map: MapData = null) -> MapData:
	if map == null:
		map = MapData.new()

	var manifest: Dictionary = data.get("manifest", {})
	map.name = manifest.get("name", "")
	map.version = int(manifest.get("version", 1))

	var layers: Variant = data.get("catalog_layers", [])
	if typeof(layers) != TYPE_ARRAY or (layers as Array).is_empty():
		map.errors.append("map declares no catalog_layers")
		return map
	map.catalog = CatalogCompiler.compile_paths(layers)
	for e in map.catalog.errors:
		map.errors.append("catalog: %s" % e)

	_parse_terrain(data, map)
	_parse_players(data, map)
	_parse_starts(data, map)

	if map.catalog.ok():
		for raw: Variant in data.get("objects", []):
			_normalize_object(raw, map)

	map.rehash()
	return map


static func _parse_terrain(data: Dictionary, map: MapData) -> void:
	var terrain: Dictionary = data.get("terrain", {})
	map.tiles_w = int(terrain.get("tiles_w", 0))
	map.tiles_h = int(terrain.get("tiles_h", 0))
	if map.tiles_w < 8 or map.tiles_h < 8 or map.tiles_w > 256 or map.tiles_h > 256:
		map.errors.append("terrain size %dx%d out of range (8..256 tiles)"
				% [map.tiles_w, map.tiles_h])


static func _parse_players(data: Dictionary, map: MapData) -> void:
	for raw: Variant in data.get("players", []):
		if typeof(raw) != TYPE_DICTIONARY:
			map.errors.append("player entry is not an object")
			continue
		var pid := int(raw.get("id", -1))
		if pid < 1:
			map.errors.append("player id %d invalid (0 is reserved for neutral)" % pid)
			continue
		map.players.append({
			"id": pid,
			"faction": str(raw.get("faction", "")),
			"start_alloy": int(raw.get("start_alloy", 0)),
			"start_flux": int(raw.get("start_flux", 0)),
		})


static func _parse_starts(data: Dictionary, map: MapData) -> void:
	for raw: Variant in data.get("starts", []):
		if typeof(raw) != TYPE_DICTIONARY:
			map.errors.append("start entry is not an object")
			continue
		map.starts.append({
			"player": int(raw.get("player", 0)),
			"cx": int(raw.get("cx", 0)),
			"cy": int(raw.get("cy", 0)),
		})


## Coordinates are pathing cells for structures/resources and fixed-point
## decimal world coordinates for units (§3).
static func _normalize_object(raw: Variant, map: MapData) -> void:
	if typeof(raw) != TYPE_DICTIONARY:
		map.errors.append("object entry is not an object")
		return
	var type: String = str(raw.get("type", ""))
	var key := map.catalog.key_of(type)
	if key == -1:
		map.errors.append("object references unknown catalog entry '%s'" % type)
		return
	var kind := map.catalog.kind_of(key)
	var player := int(raw.get("player", 0))
	match kind:
		"structure", "resource":
			if not (raw.has("cx") and raw.has("cy")):
				map.errors.append("'%s': structures/resources need cx/cy cells" % type)
				return
			var foot_w: int = map.catalog.sim_of(key)["foot_w"]
			var foot_h: int = map.catalog.sim_of(key)["foot_h"]
			var cx := int(raw.get("cx"))
			var cy := int(raw.get("cy"))
			var cells_w := map.tiles_w * SimGrid.PATH_SUBDIV
			var cells_h := map.tiles_h * SimGrid.PATH_SUBDIV
			if cx < 0 or cy < 0 or cx + foot_w > cells_w or cy + foot_h > cells_h:
				map.errors.append("'%s' at (%d, %d) hangs off the map" % [type, cx, cy])
				return
			map.objects.append({
				"type_key": key, "type": type, "player": player,
				"cx": cx, "cy": cy,
				"completed": bool(raw.get("completed", true)),
			})
		"unit":
			if not (raw.has("x") and raw.has("y")):
				map.errors.append("'%s': units need x/y world coordinates" % type)
				return
			map.objects.append({
				"type_key": key, "type": type, "player": player,
				"x": Fixed.from_decimal(str(raw.get("x"))),
				"y": Fixed.from_decimal(str(raw.get("y"))),
			})
		_:
			map.errors.append("cannot place a '%s' entry ('%s') on the map" % [kind, type])
