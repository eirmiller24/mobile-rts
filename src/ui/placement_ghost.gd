class_name PlacementGhost
extends MeshInstance3D
## The shared structure-placement ghost: a footprint box snapped to
## pathing cells with green/red/amber validity tint from a client-side
## prediction of the sim's vision-gated BUILD checks (design_m3.md §6.4).
## Used by both placement paths — the popup viewport and direct viewport
## placement — so the prediction can never disagree with itself. The sim
## is still the judge at execution; a stale prediction just no-ops.

var sim: GameSim
var local_player := 1
var world_offset := 32.0

## A vent-bound ghost within this many world units of a vent center snaps
## onto it — fingers don't have 4-cell accuracy.
const VENT_SNAP_DIST := 5.0

var type := -1
var cx := 0
var cy := 0

var _mat: StandardMaterial3D


func set_type(type_key: int) -> void:
	type = type_key
	var s := sim.catalog.sim_of(type_key)
	var box := BoxMesh.new()
	box.size = Vector3(s["foot_w"] * 0.5, 0.8, s["foot_h"] * 0.5)
	_mat = StandardMaterial3D.new()
	_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	box.material = _mat
	mesh = box


## Snap the footprint under a ground point (world coords). Vent-bound
## structures magnetize to the nearest vent in range (untaken preferred).
func move_to_world(p: Vector3) -> void:
	var s := sim.catalog.sim_of(type)
	var w: int = s["foot_w"]
	var h: int = s["foot_h"]
	if s["builds_on_vent"] and _snap_to_vent(p):
		position = footprint_center() + Vector3(0.0, 0.4, 0.0)
		return
	cx = clampi(int(floor((p.x + world_offset) * SimGrid.PATH_SUBDIV)) - w / 2,
			0, sim.grid.width - w)
	cy = clampi(int(floor((p.z + world_offset) * SimGrid.PATH_SUBDIV)) - h / 2,
			0, sim.grid.height - h)
	position = footprint_center() + Vector3(0.0, 0.4, 0.0)


## True if a vent within VENT_SNAP_DIST claimed the ghost. Untaken vents
## win over taken ones; ties go to the nearest.
func _snap_to_vent(p: Vector3) -> bool:
	var best := Vector2i(-1, -1)
	var best_taken := true
	var best_d := 0.0
	for v: Dictionary in sim.vents():
		var center := Vector2(
				(v["cx"] + v["w"] / 2.0) / SimGrid.PATH_SUBDIV - world_offset,
				(v["cy"] + v["h"] / 2.0) / SimGrid.PATH_SUBDIV - world_offset)
		var d := center.distance_to(Vector2(p.x, p.z))
		if d > VENT_SNAP_DIST:
			continue
		var better: bool = best.x == -1 \
				or (best_taken and not v["taken"]) \
				or (best_taken == v["taken"] and d < best_d)
		if better:
			best = Vector2i(v["cx"], v["cy"])
			best_taken = v["taken"]
			best_d = d
	if best.x == -1:
		return false
	cx = best.x
	cy = best.y
	return true


func footprint_center() -> Vector3:
	var s := sim.catalog.sim_of(type)
	return Vector3(
			(cx + s["foot_w"] / 2.0) / SimGrid.PATH_SUBDIV - world_offset, 0.0,
			(cy + s["foot_h"] / 2.0) / SimGrid.PATH_SUBDIV - world_offset)


## Predict validity at the current cells, tint the ghost, and return
## {"blocked": bool, "fogged": bool, "inside": bool, "info": String}.
## Visible-and-blocked fails; fog counts as free — the player's bet.
func evaluate() -> Dictionary:
	var s := sim.catalog.sim_of(type)
	var w: int = s["foot_w"]
	var h: int = s["foot_h"]
	var blocked := false
	var fogged := false
	if s["builds_on_vent"]:
		var vent := sim.vent_at(cx, cy, w, h)
		blocked = vent == 0 or sim.vent_taken(vent)
	else:
		for fy in range(cy, cy + h):
			for fx in range(cx, cx + w):
				if not sim.is_cell_visible(local_player, fx, fy):
					fogged = true
				elif sim.grid.is_blocked(fx, fy):
					blocked = true
	var center := footprint_center()
	var inside := sim.territory_covers(local_player,
			Fixed.from_float(center.x + world_offset),
			Fixed.from_float(center.z + world_offset))
	var needs_territory: bool = s["requires_territory"]
	var cost: int = s["cost_alloy"] \
			+ (0 if inside or needs_territory else s["capsule_cost_alloy"])

	var info := "%s — %d alloy" % [
			sim.catalog.ui_of(type).get("label", sim.catalog.id_of(type)), cost]
	if s["cost_flux"] > 0:
		info += " + %d flux" % s["cost_flux"]
	if not inside and not needs_territory:
		info += "  (capsule +%d)" % s["capsule_cost_alloy"]
	var color := Color(0.3, 0.9, 0.4, 0.45)
	if needs_territory and not inside:
		blocked = true
		color = Color(0.9, 0.25, 0.2, 0.5)
		info += "  NEEDS INFLUENCE — extend territory to it first"
	elif blocked:
		color = Color(0.9, 0.25, 0.2, 0.5)
		info += "  BLOCKED"
	elif fogged:
		color = Color(0.95, 0.75, 0.25, 0.5)
		info += "  unseen ground — capsule at risk"
	if _mat != null:
		_mat.albedo_color = color
	return {"blocked": blocked, "fogged": fogged, "inside": inside, "info": info}
