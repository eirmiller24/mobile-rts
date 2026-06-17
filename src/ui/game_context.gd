class_name GameUIContext
extends RefCounted
## Everything console widgets and HUD pieces need to talk to the game:
## read-only sim access (through the sim's batch view API), the
## designation store, and callables wired by the game root for issuing
## commands and moving the camera. UI code resolves designations and picks
## explicit builders/structures BEFORE a command exists — the sim never
## sees "near Bravo" (design_m3.md §4.9).

var sim: Sim
var local_player := 1
var designations: Designations
var world_offset := 32.0

## func(kind: SimCommand.Kind, targets: Array[int], params: Dictionary)
var issue := Callable()
## func(sim_x: int, sim_y: int) — center the main camera.
var jump_camera := Callable()
## func(type_key: int, sim_x: int, sim_y: int) — open the placement popup.
var open_placement := Callable()
## func(type_key: int) — arm direct in-viewport placement (ghost + bar).
var arm_placement := Callable()
## func() — disarm any in-viewport placement in progress.
var cancel_placement := Callable()
## func(text: String) — HUD status line.
var status := Callable()
## func() -> Array[int] — the current viewport selection's entity ids, sorted.
## Used by the Organize roster to snapshot a new control group.
var selected_ids := Callable()
## func(verb: String) — arm a viewport gesture verb (e.g. the Rebel draw-wall
## stroke, design_m4.md §4.4). Optional; unwired in M4's structural shell.
var arm_verb := Callable()


func affordable(type_key: int) -> bool:
	var s := sim.catalog.sim_of(type_key)
	var res := sim.resources_of(local_player)
	return res["alloy"] >= s["cost_alloy"] and res["flux"] >= s["cost_flux"]


func label_of(type_key: int) -> String:
	return sim.catalog.ui_of(type_key).get("label", sim.catalog.id_of(type_key))


func cost_text(type_key: int) -> String:
	var s := sim.catalog.sim_of(type_key)
	var text := "%d" % s["cost_alloy"]
	if s["cost_flux"] > 0:
		text += " / %d" % s["cost_flux"]
	if s.has("bandwidth") and s["bandwidth"] > 0:
		text += "  (%d bw)" % s["bandwidth"]
	return text
