class_name CatalogCompiler
## Compiles ordered catalog layers (JSON) into a CompiledCatalog
## (design_m3.md §2): load layers in order -> merge per leaf key ->
## resolve `extends` -> validate against CatalogSchema -> intern ids ->
## emit compiled sim blocks + catalog hash. All errors are collected on
## the result instead of thrown, so tests can assert on them and the M5
## editor can show them.

const ENTRY_KEYS := ["kind", "extends", "sim", "view", "ui"]


static func compile_paths(paths: Array) -> CompiledCatalog:
	var layers: Array[Dictionary] = []
	var out := CompiledCatalog.new()
	for path: String in paths:
		var text := FileAccess.get_file_as_string(path)
		if text.is_empty():
			out.errors.append("cannot read catalog layer %s" % path)
			continue
		var data: Variant = JSON.parse_string(text)
		if typeof(data) != TYPE_DICTIONARY:
			out.errors.append("catalog layer %s is not a JSON object" % path)
			continue
		layers.append(data)
	if not out.errors.is_empty():
		return out
	return compile(layers)


## `layers`: Array of Dictionaries (entry id -> raw entry), already parsed.
static func compile(layers: Array) -> CompiledCatalog:
	var out := CompiledCatalog.new()

	# 1. Merge layers in order: later layers add entries or patch existing
	# ones per leaf key (overriding rides load order, §2.1).
	var raw := {}
	for layer: Dictionary in layers:
		for id: String in layer:
			if typeof(layer[id]) != TYPE_DICTIONARY:
				out.errors.append("entry '%s' is not an object" % id)
				continue
			for k: String in layer[id]:
				if k not in ENTRY_KEYS:
					out.errors.append("entry '%s': unknown key '%s'" % [id, k])
			if raw.has(id):
				_deep_merge(raw[id], layer[id])
			else:
				raw[id] = (layer[id] as Dictionary).duplicate(true)

	# 2. Resolve each entry's kind through its extends chain. Kind is fixed
	# at the root; cycles and kind changes are compile errors (§2.2).
	var kind_of := {}
	var visit_state := {}
	for id: String in raw:
		_resolve_kind(id, raw, kind_of, visit_state, out)
	if not out.errors.is_empty():
		return out

	# 3. Resolve extends: derived entries replace base fields per leaf key.
	var resolved := {}
	for id: String in raw:
		_resolve_entry(id, raw, resolved)

	# 4. The classes singleton compiles first — its lists define the
	# attack/armor class enums every other entry references.
	var classes_ids: Array[String] = []
	for id: String in raw:
		if kind_of[id] == "classes":
			classes_ids.append(id)
	if classes_ids.size() != 1:
		out.errors.append("expected exactly one 'classes' entry, found %d"
				% classes_ids.size())
		return out
	var classes_id: String = classes_ids[0]
	_compile_classes(classes_id, resolved[classes_id]["sim"], out)
	if not out.errors.is_empty():
		return out

	# 5. Intern: all ids sorted lexicographically, index = type_key (§2.4).
	var sorted_ids := PackedStringArray(raw.keys())
	sorted_ids.sort()
	out._set_interning(sorted_ids)
	var ctx := {"out": out, "kind_of": kind_of}

	# 6. Compile every entry's sim block against its kind's schema.
	for id in sorted_ids:
		var kind: String = kind_of[id]
		out.kinds.append(kind)
		out.sim_blocks.append(_compile_sim(id, kind, resolved[id]["sim"], ctx))
		out.view_blocks.append(resolved[id]["view"])
		out.ui_blocks.append(resolved[id]["ui"])
	_post_validate(out)
	if not out.errors.is_empty():
		return out

	# 7. Flag -> granting-ability index (§4.3).
	for key in out.size():
		if out.kinds[key] != "ability":
			continue
		var sim := out.sim_blocks[key]
		if sim["ability_kind"] != CatalogSchema.AbilityKind.AURA:
			continue
		for flag: String in sim["flags"]:
			if not out.flag_abilities.has(flag):
				out.flag_abilities[flag] = PackedInt32Array()
			out.flag_abilities[flag].append(key)

	# 8. Content hash over kinds, ids, and compiled sim blocks in key
	# order. view/ui are deliberately excluded (§2.2).
	var buf := PackedByteArray()
	for key in out.size():
		SimHash.fold_value(buf, out.ids[key])
		SimHash.fold_value(buf, out.kinds[key])
		SimHash.fold_value(buf, out.sim_blocks[key])
	out.hash_value = SimHash.fnv_bytes(buf)
	return out


# --- merge and extends resolution --------------------------------------------


## Merge `b` into `a` per leaf key: nested Dictionaries merge recursively,
## everything else replaces. There is no field deletion (§2.2).
static func _deep_merge(a: Dictionary, b: Dictionary) -> void:
	for k: Variant in b:
		if a.has(k) and typeof(a[k]) == TYPE_DICTIONARY \
				and typeof(b[k]) == TYPE_DICTIONARY:
			_deep_merge(a[k], b[k])
		else:
			a[k] = b[k].duplicate(true) if typeof(b[k]) in \
					[TYPE_DICTIONARY, TYPE_ARRAY] else b[k]


## Returns the entry's root kind, walking extends with cycle detection.
static func _resolve_kind(id: String, raw: Dictionary, kind_of: Dictionary,
		visit_state: Dictionary, out: CompiledCatalog) -> String:
	if kind_of.has(id):
		return kind_of[id]
	if visit_state.get(id, 0) == 1:
		out.errors.append("entry '%s': extends cycle" % id)
		kind_of[id] = ""
		return ""
	visit_state[id] = 1
	var e: Dictionary = raw[id]
	var declared: String = e.get("kind", "")
	var kind := declared
	if e.has("extends"):
		var base: String = e["extends"]
		if not raw.has(base):
			out.errors.append("entry '%s': extends unknown entry '%s'" % [id, base])
			kind = ""
		else:
			var base_kind := _resolve_kind(base, raw, kind_of, visit_state, out)
			if not declared.is_empty() and declared != base_kind:
				out.errors.append("entry '%s': cannot change kind '%s' -> '%s'"
						% [id, base_kind, declared])
			kind = base_kind
	elif declared.is_empty():
		out.errors.append("entry '%s': missing kind" % id)
	elif declared not in CatalogSchema.KINDS:
		out.errors.append("entry '%s': unknown kind '%s'" % [id, declared])
		kind = ""
	visit_state[id] = 2
	kind_of[id] = kind
	return kind


## Full sim/view/ui sections with the extends chain applied. Cycles were
## already rejected by _resolve_kind.
static func _resolve_entry(id: String, raw: Dictionary,
		resolved: Dictionary) -> Dictionary:
	if resolved.has(id):
		return resolved[id]
	var e: Dictionary = raw[id]
	var result := {"sim": {}, "view": {}, "ui": {}}
	if e.has("extends") and raw.has(e["extends"]):
		var base := _resolve_entry(e["extends"], raw, resolved)
		for section in ["sim", "view", "ui"]:
			result[section] = (base[section] as Dictionary).duplicate(true)
	for section in ["sim", "view", "ui"]:
		var own: Variant = e.get(section, {})
		if typeof(own) == TYPE_DICTIONARY:
			_deep_merge(result[section], own)
	resolved[id] = result
	return result


# --- per-kind compilation -----------------------------------------------------


static func _compile_classes(id: String, sim_raw: Dictionary,
		out: CompiledCatalog) -> void:
	for list_field in ["attack_classes", "armor_classes"]:
		var v: Variant = sim_raw.get(list_field)
		if typeof(v) != TYPE_ARRAY or (v as Array).is_empty():
			out.errors.append("'%s': %s must be a non-empty list" % [id, list_field])
			return
		for name: Variant in v:
			if typeof(name) != TYPE_STRING:
				out.errors.append("'%s': %s entries must be strings" % [id, list_field])
				return
	out.attack_classes = PackedStringArray(sim_raw["attack_classes"])
	out.armor_classes = PackedStringArray(sim_raw["armor_classes"])

	var m: Variant = sim_raw.get("matrix")
	if typeof(m) != TYPE_DICTIONARY:
		out.errors.append("'%s': missing damage matrix" % id)
		return
	out.matrix.resize(out.attack_classes.size() * out.armor_classes.size())
	for a in out.attack_classes.size():
		var row: Variant = (m as Dictionary).get(out.attack_classes[a])
		if typeof(row) != TYPE_DICTIONARY:
			out.errors.append("'%s': matrix missing attack class '%s'"
					% [id, out.attack_classes[a]])
			continue
		for r in out.armor_classes.size():
			var cell: Variant = (row as Dictionary).get(out.armor_classes[r])
			if typeof(cell) != TYPE_STRING or not _is_decimal(cell):
				out.errors.append("'%s': matrix[%s][%s] must be a decimal string"
						% [id, out.attack_classes[a], out.armor_classes[r]])
				continue
			out.matrix[a * out.armor_classes.size() + r] = Fixed.from_decimal(cell)
	for row_key: Variant in m:
		if row_key not in out.attack_classes:
			out.errors.append("'%s': matrix has unknown attack class '%s'" % [id, row_key])

	# Globals ride the same schema table as ordinary fields.
	var ctx := {"out": out, "kind_of": {}}
	for fname: String in CatalogSchema.CLASSES:
		var spec: Dictionary = CatalogSchema.CLASSES[fname]
		if spec["type"] in ["string_list", "matrix"]:
			continue
		var present: bool = sim_raw.has(fname)
		var value: Variant = sim_raw[fname] if present else spec.get("default")
		out.globals[fname] = _compile_field(id, fname, spec, value, ctx)


static func _compile_sim(id: String, kind: String, sim_raw: Dictionary,
		ctx: Dictionary) -> Dictionary:
	var out: CompiledCatalog = ctx["out"]
	var schema := CatalogSchema.fields_for(kind)
	if schema.is_empty():
		return {}
	for fname: String in sim_raw:
		if not schema.has(fname):
			out.errors.append("'%s': unknown sim field '%s'" % [id, fname])
	var compiled := {}
	for fname: String in schema:
		var spec: Dictionary = schema[fname]
		if kind == "classes" and spec["type"] in ["string_list", "matrix"]:
			compiled[fname] = PackedStringArray(sim_raw.get(fname, [])) \
					if spec["type"] == "string_list" else out.matrix
			continue
		if sim_raw.has(fname):
			compiled[fname] = _compile_field(id, fname, spec, sim_raw[fname], ctx)
		elif spec.get("required", false):
			out.errors.append("'%s': missing required field '%s'" % [id, fname])
			compiled[fname] = _compile_field(id, fname, spec,
					spec.get("default", 0), ctx)
		else:
			compiled[fname] = _compile_field(id, fname, spec, spec["default"], ctx)
	return compiled


## One field, authored form -> compiled form (see CatalogSchema header).
## Returns a safe zero value alongside an error so compilation can continue
## collecting problems.
static func _compile_field(id: String, fname: String, spec: Dictionary,
		value: Variant, ctx: Dictionary) -> Variant:
	var out: CompiledCatalog = ctx["out"]
	match spec["type"]:
		"int":
			var i := 0
			if typeof(value) == TYPE_INT:
				i = value
			elif typeof(value) == TYPE_FLOAT and value == floorf(value):
				i = int(value)
			else:
				out.errors.append("'%s'.%s: expected an integer" % [id, fname])
				return 0
			if i < spec.get("min", -(1 << 62)) or i > spec.get("max", 1 << 62):
				out.errors.append("'%s'.%s: %d out of range" % [id, fname, i])
			return i
		"fixed":
			if typeof(value) != TYPE_STRING or not _is_decimal(value):
				out.errors.append(
						"'%s'.%s: fixed values are decimal strings like \"2.5\""
						% [id, fname])
				return 0
			return Fixed.from_decimal(value)
		"seconds":
			return _compile_seconds(id, fname, value, out)
		"bool":
			if typeof(value) != TYPE_BOOL:
				out.errors.append("'%s'.%s: expected true/false" % [id, fname])
				return false
			return value
		"enum":
			var values: Array = spec["values"]
			var idx := values.find(value)
			if idx == -1:
				out.errors.append("'%s'.%s: '%s' not one of %s"
						% [id, fname, value, values])
				return 0
			return idx
		"attack_class", "armor_class":
			if typeof(value) != TYPE_STRING:
				out.errors.append("'%s'.%s: expected a class name" % [id, fname])
				return -1
			if value == "":
				return -1
			var list := out.attack_classes if spec["type"] == "attack_class" \
					else out.armor_classes
			var idx := list.find(value)
			if idx == -1:
				out.errors.append("'%s'.%s: unknown class '%s'" % [id, fname, value])
			return idx
		"id_list":
			var keys := PackedInt32Array()
			if typeof(value) != TYPE_ARRAY:
				out.errors.append("'%s'.%s: expected a list of entry ids" % [id, fname])
				return keys
			for ref: Variant in value:
				var key: int = out.key_of(ref) if typeof(ref) == TYPE_STRING else -1
				if key == -1:
					out.errors.append("'%s'.%s: unknown entry '%s'" % [id, fname, ref])
					continue
				if ctx["kind_of"].get(ref, "") != spec["kind"]:
					out.errors.append("'%s'.%s: '%s' is not a %s"
							% [id, fname, ref, spec["kind"]])
					continue
				keys.append(key)
			return keys
		"flags", "string_list":
			var strings := PackedStringArray()
			if typeof(value) != TYPE_ARRAY:
				out.errors.append("'%s'.%s: expected a list of strings" % [id, fname])
				return strings
			for s: Variant in value:
				if typeof(s) != TYPE_STRING:
					out.errors.append("'%s'.%s: expected strings" % [id, fname])
					continue
				strings.append(s)
			return strings
		"modifiers":
			var mods := {}
			if typeof(value) != TYPE_DICTIONARY:
				out.errors.append("'%s'.%s: expected a dictionary" % [id, fname])
				return mods
			for mkey: Variant in value:
				if not CatalogSchema.MODIFIERS.has(mkey):
					out.errors.append("'%s'.%s: unknown modifier '%s'" % [id, fname, mkey])
					continue
				mods[mkey] = _compile_field(id, "%s.%s" % [fname, mkey],
						CatalogSchema.MODIFIERS[mkey], value[mkey], ctx)
			return mods
		"stat_overrides":
			var overrides := {}
			if typeof(value) != TYPE_DICTIONARY:
				out.errors.append("'%s'.%s: expected a dictionary" % [id, fname])
				return overrides
			for okey: Variant in value:
				var ospec: Dictionary = CatalogSchema.UNIT.get(okey, {})
				if ospec.is_empty() or ospec["type"] == "id_list":
					out.errors.append("'%s'.%s: cannot override '%s'" % [id, fname, okey])
					continue
				overrides[okey] = _compile_field(id, "%s.%s" % [fname, okey],
						ospec, value[okey], ctx)
			return overrides
	out.errors.append("'%s'.%s: unhandled type '%s'" % [id, fname, spec["type"]])
	return 0


## Durations land on whole ticks or fail: silent rounding is how balance
## bugs hide (§2.3).
static func _compile_seconds(id: String, fname: String, value: Variant,
		out: CompiledCatalog) -> int:
	if typeof(value) != TYPE_STRING or not _is_decimal(value) \
			or value.begins_with("-"):
		out.errors.append(
				"'%s'.%s: durations are decimal strings like \"1.5\"" % [id, fname])
		return 0
	var s: String = value
	var dot := s.find(".")
	var int_part := s if dot == -1 else s.substr(0, dot)
	var frac_part := "" if dot == -1 else s.substr(dot + 1)
	var num := 0
	var den := 1
	for ch in frac_part:
		num = num * 10 + (ch.unicode_at(0) - 48)
		den *= 10
	var whole := 0
	for ch in int_part:
		whole = whole * 10 + (ch.unicode_at(0) - 48)
	var total := whole * den + num
	if (total * Sim.TICK_RATE) % den != 0:
		out.errors.append(
				"'%s'.%s: \"%s\" s is not a whole number of ticks (multiple of 0.05)"
				% [id, fname, value])
		return 0
	return total * Sim.TICK_RATE / den


static func _is_decimal(s: String) -> bool:
	var i := 1 if s.begins_with("-") else 0
	if i >= s.length():
		return false
	var digits := 0
	var dot := -1
	for j in range(i, s.length()):
		var ch := s[j]
		if ch == ".":
			if dot != -1:
				return false
			dot = j
		elif ch >= "0" and ch <= "9":
			digits += 1
		else:
			return false
	if digits == 0 or s.ends_with("."):
		return false
	if dot != -1 and s.length() - dot - 1 > 9:
		return false
	return true


## Cross-field rules that single-field specs can't express.
static func _post_validate(out: CompiledCatalog) -> void:
	for key in out.size():
		var id := out.ids[key]
		var sim := out.sim_blocks[key]
		var kind := out.kinds[key]
		if kind == "unit" or kind == "structure":
			if sim["armor_class"] == -1:
				out.errors.append("'%s': %s needs an armor_class" % [id, kind])
			if sim["damage"] > 0 and sim["attack_class"] == -1:
				out.errors.append("'%s': has damage but no attack_class" % id)
			if sim["acquire_range"] > sim["sight"] and sim["damage"] > 0:
				push_warning("catalog '%s': acquire_range exceeds sight — it will fight things its player can't see" % id)
		if kind == "ability" and sim["ability_kind"] == CatalogSchema.AbilityKind.AURA \
				and sim["radius"] <= 0:
			out.errors.append("'%s': aura needs a positive radius" % id)


