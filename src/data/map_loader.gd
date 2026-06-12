class_name MapLoader
## Parses a map file (design_m3.md §3) into MapData: reads the manifest,
## compiles the declared catalog layers, validates and normalizes the
## object list, and hashes the parsed content. All problems are collected
## on the result, never thrown.


static func load_path(path: String) -> MapData:
	var map := MapData.new()
	var text := FileAccess.get_file_as_string(path)
	if text.is_empty():
		map.errors.append("cannot read map %s" % path)
		return map
	var data: Variant = JSON.parse_string(text)
	if typeof(data) != TYPE_DICTIONARY:
		map.errors.append("map %s is not a JSON object" % path)
		return map
	return load_dict(data, map)


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

	var terrain: Dictionary = data.get("terrain", {})
	map.tiles_w = int(terrain.get("tiles_w", 0))
	map.tiles_h = int(terrain.get("tiles_h", 0))
	if map.tiles_w < 8 or map.tiles_h < 8 or map.tiles_w > 256 or map.tiles_h > 256:
		map.errors.append("terrain size %dx%d out of range (8..256 tiles)"
				% [map.tiles_w, map.tiles_h])

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

	if map.catalog.ok():
		for raw: Variant in data.get("objects", []):
			_normalize_object(raw, map)

	map.rehash()
	return map


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
