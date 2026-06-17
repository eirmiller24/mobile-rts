extends SceneTree
## Headless check that the default UI catalog parses and every binding it
## references exists. Guards the "UI as Data" rule: if a button or context
## order points at an undefined command, CI fails before a human taps it.
##
## Run on the host:
##   flatpak run org.godotengine.Godot --headless --path . \
##     -s res://tests/ui_catalog_check.gd

var failures := 0


func _initialize() -> void:
	var catalog := UICatalog.load_from_json("res://data/ui/default_ui.json")
	if catalog == null:
		print("ui_catalog_check: FAILED (could not load)")
		quit(1)
		return
	var problems := catalog.validate()
	for p in problems:
		push_error(p)
		failures += 1

	# The Tactics tab is now a real stance_picker (M4).
	_expect(catalog.console_screens["tactics"].widgets[0].type == "stance_picker",
			"tactics tab should host the stance_picker widget")

	_check_rebel_layer()
	_check_designations()

	if failures == 0:
		print("ui_catalog_check: OK (%d commands, %d buttons)"
				% [catalog.commands.size(), catalog.side_buttons.size()])
		quit(0)
	else:
		print("ui_catalog_check: FAILED (%d problems)" % failures)
		quit(1)


func _expect(cond: bool, msg: String) -> void:
	if not cond:
		push_error(msg)
		failures += 1


## The Rebel UI layer (design_m4.md §13.2) overrides the Hive defaults through
## the same layer mechanism the object catalog uses — proof "UI as data"
## carries a whole second faction.
func _check_rebel_layer() -> void:
	var rebel := UICatalog.load_layers([
		"res://data/ui/default_ui.json", "res://data/ui/rebels_ui.json"])
	_expect(rebel != null, "rebel UI layer loaded")
	if rebel == null:
		return
	var problems := rebel.validate()
	for p in problems:
		push_error("rebel UI: %s" % p)
		failures += 1
	# The supply slot is relabeled Crew (the dividend M3 §6.7 reserved).
	_expect(rebel.hud_labels["bandwidth"] == "Crew", "Crew label override")
	# The Mine context order replaces the Hive's resource -> move.
	_expect(rebel.context_orders["resource"] == "mine", "mine context order")
	_expect(rebel.commands.has("mine"), "mine verb defined")
	# The economy tab swaps nano sliders for worker intent dials (same tab id).
	_expect(rebel.console_screens["economy"].widgets[0].type == "worker_dials",
			"economy tab bound to worker_dials for the Rebels")
	# Walls have no separate verb: picking the is_wall Barricade from the build
	# grid arms the stroke gesture (design_m4.md §4.4). Confirm it's buildable.
	var rebel_cat := CatalogCompiler.compile_paths([
			"res://data/catalog/core.json", "res://data/catalog/rebels.json"])
	_expect(rebel_cat.ok(), "rebel catalog compiles")
	var bar := rebel_cat.key_of("rebels.barricade")
	_expect(bar != -1 and rebel_cat.sim_of(bar).get("is_wall", false),
			"Barricade is flagged is_wall (drawn, not a verb)")
	# The Hive layer alone has no Crew label / mine order (override is additive).
	var hive := UICatalog.load_from_json("res://data/ui/default_ui.json")
	_expect(hive.hud_labels["bandwidth"] == "Bandwidth", "Hive keeps Bandwidth")
	_expect(hive.context_orders["resource"] == "move", "Hive resource -> move")


## The designation store is plain logic, so it gets checked headless here:
## auto-naming, slot assignment/recall, and pruning of dead groups.
func _check_designations() -> void:
	var d := Designations.new()
	var s0 := d.assign_group([3, 1, 2] as Array[int])
	var s1 := d.assign_group([7] as Array[int])
	_expect(s0 == 0 and s1 == 1, "groups should fill slots in order")
	_expect(d.entry(0)["name"] == "Alpha" and d.entry(1)["name"] == "Bravo",
			"auto names should be Alpha, Bravo")
	var s2 := d.add_location(Fixed.from_int(5), Fixed.from_int(6))
	_expect(s2 == 2 and d.entry(2)["kind"] == "location", "location pins a slot")
	_expect(d.locations().size() == 1, "one location designation")

	# Pruning: unit 7 dies -> Bravo frees its slot; Alpha loses one member.
	d.prune(func(id: int) -> bool: return id != 7 and id != 3)
	_expect(d.entry(1) == null, "empty group should free its slot")
	_expect(d.entry(0)["ids"] == ([1, 2] as Array[int]), "dead ids drop from groups")

	# The freed slot is reused, and the name Bravo is free again.
	var s3 := d.assign_group([9] as Array[int])
	_expect(s3 == 1 and d.entry(1)["name"] == "Bravo", "freed slot and name reused")

	# Explicit slot overwrite.
	d.assign_group([4, 5] as Array[int], 0)
	_expect(d.entry(0)["ids"].size() == 2, "explicit slot assignment overwrites")

	# Cap: fill everything, the 9th fails.
	for i in 8:
		d.assign_group([100 + i] as Array[int])
	_expect(d.assign_group([999] as Array[int]) == -1, "9th designation must fail")
