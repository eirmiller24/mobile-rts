extends Node3D
## Game root: owns the sim, drives it at a fixed tick rate, and assembles
## the HUD (from the UI catalog), selection controller, and unit views.
## The view layer reads sim state and renders it interpolated between
## ticks; it influences the sim exclusively by scheduling SimCommands.

const TICK_DT := 1.0 / Sim.TICK_RATE
const MAP_PATH := "res://maps/dev_arena.json"
const SIM_SEED := 0xC0FFEE

## Engine verbs the sim understands. The catalog binds buttons/taps to
## command ids; this table is the engine implementing those verbs, not a
## button binding (see design.md "UI as Data"). Verbs the sim can't express
## yet degrade gracefully: patrol/mine move (M3/M4), hold stops.
const VERB_KIND := {
	"move": SimCommand.Kind.MOVE,
	"patrol": SimCommand.Kind.MOVE,
	"mine": SimCommand.Kind.MOVE,
	"attack": SimCommand.Kind.ATTACK_MOVE,
	"attack_move": SimCommand.Kind.ATTACK_MOVE,
	"stop": SimCommand.Kind.STOP,
	"hold": SimCommand.Kind.STOP,
}

## Player 0 is reserved for neutral/hostile-neutral map objects (§3).
const LOCAL_PLAYER := 1

var sim: Sim
var map: MapData
var catalog: UICatalog
var hud: Hud
var controller: SelectionController
var designations: Designations
var ctx: GameUIContext
var placement: PlacementPopup
var viewport_placement: ViewportPlacement
## The sim's origin is the map corner; the view keeps the map centered.
var world_offset := 32.0

var _accumulator := 0.0
var _cmd_seq := 0
## entity id -> UnitView, plus per-id previous/current sim positions for
## render interpolation between ticks.
var _views := {}
var _prev := {}
var _cur := {}

@onready var camera_rig: CameraRig = $CameraRig
@onready var camera: Camera3D = $CameraRig/Camera3D


func _ready() -> void:
	map = MapLoader.load_path(MAP_PATH)
	if not map.ok():
		for e in map.errors:
			push_error("map: %s" % e)
		return
	world_offset = map.tiles_w / 2.0
	sim = Sim.new(SIM_SEED, map.catalog, map)
	catalog = UICatalog.load_default()
	if catalog == null:
		push_error("UI catalog failed to load; controls disabled")
		return
	for problem in catalog.validate():
		push_error("UI catalog: %s" % problem)

	designations = Designations.new()
	ctx = GameUIContext.new()
	ctx.sim = sim
	ctx.local_player = LOCAL_PLAYER
	ctx.designations = designations
	ctx.world_offset = world_offset
	ctx.issue = _issue_command
	ctx.jump_camera = jump_camera_to_sim
	ctx.open_placement = _open_placement
	ctx.arm_placement = func(type_key: int) -> void:
		viewport_placement.begin(type_key)
	ctx.cancel_placement = func() -> void:
		viewport_placement.cancel_placement()
	ctx.status = func(text: String) -> void: hud.set_status(text)
	ctx.selected_ids = _selected_entity_ids

	hud = Hud.new()
	hud.catalog = catalog
	hud.designations = designations
	hud.ctx = ctx
	add_child(hud)
	camera_rig.ui_occluder = hud.is_point_on_ui

	# Direct in-viewport placement: ghost + floating confirm bar.
	viewport_placement = ViewportPlacement.new()
	viewport_placement.sim = sim
	viewport_placement.local_player = LOCAL_PLAYER
	viewport_placement.world_offset = world_offset
	viewport_placement.ghost_parent = self
	viewport_placement.place_confirmed.connect(_on_place_confirmed)
	hud.add_child(viewport_placement)
	hud.extra_occluders.append(viewport_placement)

	# Placement popup above the console (added after, so it draws on top).
	placement = PlacementPopup.new()
	placement.sim = sim
	placement.local_player = LOCAL_PLAYER
	placement.world_offset = world_offset
	placement.ghost_parent = self
	placement.place_confirmed.connect(_on_place_confirmed)
	hud.add_child(placement)

	controller = SelectionController.new()
	controller.camera = camera
	controller.hud = hud
	controller.catalog = catalog
	add_child(controller)

	hud.command_chosen.connect(controller.choose_command)
	# Reselect / auto-deselect stay on the controller (dormant) for an easy
	# future restore; nothing wires them now that the corner button is gone.
	controller.selection_changed.connect(_on_selection_changed)
	controller.order_issued.connect(_on_order_issued)

	controller.placement_tap = viewport_placement.handle_tap
	controller.long_pressed.connect(_on_ground_long_pressed)
	hud.control_button.deselect_all_requested.connect(controller.deselect_all)
	hud.control_button.new_group_requested.connect(_on_new_group_from_selection)
	hud.chips.chip_tapped.connect(_on_chip_tapped)
	hud.locations_button.location_selected.connect(_on_designation_recall)

	var fog := FogOverlay.new()
	fog.sim = sim
	fog.local_player = LOCAL_PLAYER
	fog.world_offset = world_offset
	add_child(fog)
	var territory := TerritoryDecal.new()
	territory.sim = sim
	territory.local_player = LOCAL_PLAYER
	territory.world_offset = world_offset
	add_child(territory)

	_sync_views()


func _process(delta: float) -> void:
	_accumulator += minf(delta, 0.25) # clamp away hitches/debugger pauses
	while _accumulator >= TICK_DT:
		sim.step()
		_capture_tick()
		_accumulator -= TICK_DT
	_interpolate_views(_accumulator / TICK_DT)


## Create views for sim entities that don't have one yet (map spawns at
## startup, trained units and capsules later). Views are catalog-driven
## primitives; real models land in the catalog's view blocks without
## code changes (design_m3.md §7.1).
func _sync_views() -> void:
	for id in sim.entities:
		if _views.has(id):
			continue
		var e: SimEntity = sim.entities[id]
		var pos := _sim_to_view(e)
		var view := UnitView.from_entity(e, map.catalog.view_of(e.type_key),
				_faction_of(e), pos)
		add_child(view)
		_views[id] = view
		_prev[id] = pos
		_cur[id] = pos


func _faction_of(e: SimEntity) -> int:
	if e.player == LOCAL_PLAYER:
		return UnitView.FACTION_PLAYER
	if e.is_resource():
		return UnitView.FACTION_NEUTRAL
	return UnitView.FACTION_ENEMY


## After each sim tick: roll interpolation targets, create views for new
## entities, and drop views whose entities died.
func _capture_tick() -> void:
	_sync_views()
	designations.prune(func(id: int) -> bool:
		var e: SimEntity = sim.entities.get(id)
		return e != null and e.hp > 0)
	var capsule_time: int = map.catalog.globals["capsule_time"]
	for id in _views.keys():
		var e: SimEntity = sim.entities.get(id)
		if e == null:
			_views[id].queue_free()
			_views.erase(id)
			_prev.erase(id)
			_cur.erase(id)
			continue
		_prev[id] = _cur[id]
		_cur[id] = _sim_to_view(e)
		# Two-state fog: own entities and resource nodes always render;
		# other players' dynamic entities hide under fog (§4.4).
		var view: UnitView = _views[id]
		view.visible = e.player == LOCAL_PLAYER or e.is_resource() \
				or sim.is_tile_visible(LOCAL_PLAYER,
						Fixed.to_int(e.x), Fixed.to_int(e.y))
		view.sync_state(e, capsule_time)


func _interpolate_views(alpha: float) -> void:
	var t := clampf(alpha, 0.0, 1.0)
	for id in _views:
		_views[id].position = _prev[id].lerp(_cur[id], t)


func _sim_to_view(e: SimEntity) -> Vector3:
	return Vector3(Fixed.to_float(e.x) - world_offset, 0.0,
			Fixed.to_float(e.y) - world_offset)


func _on_selection_changed(units: Array[UnitView]) -> void:
	hud.set_status("" if units.is_empty() else "%d selected" % units.size())
	_populate_ability_button(units)


## Fill the selection_abilities side button's radial from the majority
## type's catalog abilities (design_m3.md §6.7): the radial idiom is
## engine code, what the slots mean is data from the object catalog.
func _populate_ability_button(units: Array[UnitView]) -> void:
	var btn: RadialButton = null
	for b in hud.buttons:
		if b.def.selection_abilities:
			btn = b
	if btn == null:
		return
	btn.def.radial = {}
	var majority := _majority_type(units)
	if majority == -1:
		btn.queue_redraw()
		return
	var dirs := ["up", "right", "down", "left"]
	var slot := 0
	for ak in map.catalog.sim_of(majority).get("abilities", PackedInt32Array()):
		var ab := map.catalog.sim_of(ak)
		var kind: int = ab["ability_kind"]
		if kind != CatalogSchema.AbilityKind.TOGGLE_MORPH \
				and kind != CatalogSchema.AbilityKind.BLINK:
			continue # build is console macro; auras are passive
		if slot >= dirs.size():
			break
		var cmd_id := "ability:%s" % map.catalog.id_of(ak)
		if not catalog.commands.has(cmd_id):
			var def := UICatalog.CommandDef.new()
			def.id = cmd_id
			def.label = map.catalog.ui_of(ak).get("label", map.catalog.id_of(ak))
			def.color = Color(0.45, 0.85, 0.65)
			def.targeted = kind == CatalogSchema.AbilityKind.BLINK
			catalog.commands[cmd_id] = def
		btn.def.radial[dirs[slot]] = cmd_id
		slot += 1
	btn.queue_redraw()


## Most common unit type among the selection (lowest type_key on ties).
func _majority_type(units: Array[UnitView]) -> int:
	var counts := {}
	for u in units:
		var e: SimEntity = sim.entities.get(u.entity_id) if is_instance_valid(u) else null
		if e != null and e.is_unit():
			counts[e.type_key] = counts.get(e.type_key, 0) + 1
	var best := -1
	for type: int in counts:
		if best == -1 or counts[type] > counts[best] \
				or (counts[type] == counts[best] and type < best):
			best = type
	return best


# --- designations (design_m3.md §6.1) ------------------------------------------


func _on_ground_long_pressed(world_pos: Vector3) -> void:
	var slot := designations.add_location(
			Fixed.from_float(world_pos.x + world_offset),
			Fixed.from_float(world_pos.z + world_offset))
	hud.set_status("designated %s" % designations.entry(slot)["name"]
			if slot != -1 else "no free designation slots")


## The control button's "New group" petal: snapshot the current selection into
## a fresh group (empty if nothing is selected — units can be added later).
func _on_new_group_from_selection() -> void:
	var ids := _selected_entity_ids()
	var slot := designations.assign_group(ids, -1, true)
	if slot == -1:
		hud.set_status("no free group slots")
		return
	hud.set_status("%s = %d units" % [designations.entry(slot)["name"], ids.size()])


## Tapping a control-group chip recalls that group; with the control modifier
## held it instead overwrites the group with the current selection (design.md
## "The control button").
func _on_chip_tapped(slot: int) -> void:
	if not hud.control_held():
		_on_designation_recall(slot)
		return
	var ids := _selected_entity_ids()
	if ids.is_empty():
		hud.set_status("select units first to set a group")
		return
	var used := designations.set_group(slot, ids)
	if used != -1:
		hud.set_status("%s = %d units" % [designations.entry(used)["name"], ids.size()])


func _on_designation_recall(slot: int) -> void:
	var e: Variant = designations.entry(slot)
	if e == null:
		return
	if e["kind"] == "location":
		jump_camera_to_sim(e["x"], e["y"])
	else:
		var views: Array[UnitView] = []
		for id: int in e["ids"]:
			if _views.has(id):
				views.append(_views[id])
		if not views.is_empty():
			controller._select(views)


func _selected_entity_ids() -> Array[int]:
	var ids: Array[int] = []
	for u in controller.selection:
		if is_instance_valid(u) and u.entity_id > 0:
			ids.append(u.entity_id)
	ids.sort()
	return ids


func jump_camera_to_sim(x: int, y: int) -> void:
	camera_rig.position = Vector3(Fixed.to_float(x) - world_offset, 0.0,
			Fixed.to_float(y) - world_offset)


func _on_order_issued(command_id: String, units: Array[UnitView],
		world_pos: Vector3, target: UnitView) -> void:
	var ids: Array[int] = []
	for u in units:
		if is_instance_valid(u) and u.entity_id > 0:
			ids.append(u.entity_id)
	ids.sort()
	if ids.is_empty():
		return

	var params := {
		"x": Fixed.from_float(world_pos.x + world_offset),
		"y": Fixed.from_float(world_pos.z + world_offset),
	}
	if command_id.begins_with("ability:"):
		params["ability"] = map.catalog.key_of(command_id.trim_prefix("ability:"))
		_issue_command(SimCommand.Kind.ABILITY, ids, params)
	else:
		var kind: SimCommand.Kind = VERB_KIND.get(command_id, SimCommand.Kind.MOVE)
		if kind == SimCommand.Kind.STOP:
			_issue_command(kind, ids, {})
		else:
			# Holding the control modifier queues the order (append) instead of
			# replacing the unit's current orders — see Sim._order_move.
			if hud.control_held():
				params["queue"] = true
			_issue_command(kind, ids, params)

	OrderMarker.spawn(self, world_pos, catalog.command(command_id).color)
	var target_desc := "" if target == null else " (target: %s/%s)" % [
			UnitView.Kind.keys()[target.kind], target.faction]
	print("[order] %s x%d -> %v%s" % [command_id, ids.size(), world_pos, target_desc])


## The single seam every UI path schedules commands through.
func _issue_command(kind: SimCommand.Kind, targets: Array[int],
		params: Dictionary) -> void:
	var cmd := SimCommand.new(LOCAL_PLAYER, kind)
	cmd.targets = targets
	cmd.params = params
	cmd.seq = _cmd_seq
	_cmd_seq += 1
	sim.schedule(cmd)


# --- build placement (design_m3.md §6.3/§6.4) -----------------------------------


func _open_placement(type_key: int, sim_x: int, sim_y: int) -> void:
	placement.begin(type_key, sim_x, sim_y)


func _on_place_confirmed(type_key: int, cx: int, cy: int) -> void:
	var builder := sim.builder_for(LOCAL_PLAYER, type_key)
	if builder == 0:
		hud.set_status("nothing can build that")
		return
	_issue_command(SimCommand.Kind.BUILD, [builder],
			{"type": type_key, "cx": cx, "cy": cy})
	hud.set_status("building %s" % ctx.label_of(type_key))
	# Single-build returns the console to the tab root; continuous re-arms.
	hud.console.notify_build_committed()
