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
