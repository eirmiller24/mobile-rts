extends SceneTree
## Headless check that the default UI catalog parses and every binding it
## references exists. Guards the "UI as Data" rule: if a button or context
## order points at an undefined command, CI fails before a human taps it.
##
## Run on the host:
##   flatpak run org.godotengine.Godot --headless --path . \
##     -s res://tests/ui_catalog_check.gd

func _initialize() -> void:
	var catalog := UICatalog.load_from_json("res://data/ui/default_ui.json")
	if catalog == null:
		print("ui_catalog_check: FAILED (could not load)")
		quit(1)
		return
	var problems := catalog.validate()
	for p in problems:
		push_error(p)
	if problems.is_empty():
		print("ui_catalog_check: OK (%d commands, %d buttons)"
				% [catalog.commands.size(), catalog.side_buttons.size()])
		quit(0)
	else:
		print("ui_catalog_check: FAILED (%d problems)" % problems.size())
		quit(1)
