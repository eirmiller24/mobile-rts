extends Node3D
## Game root: owns the sim, drives it at a fixed tick rate, and assembles
## the HUD (from the UI catalog), selection controller, and unit views.
## The view layer reads sim state and renders it interpolated between
## ticks; it influences the sim exclusively by scheduling SimCommands.

const TICK_DT := 1.0 / Sim.TICK_RATE
## M4 ships the 1v1 clash map (human vs bot); dev_arena.json stays the Hive
## sandbox. Swap this back for the single-player sandbox.
const MAP_PATH := "res://maps/dev_clash.json"
const SIM_SEED := 0xC0FFEE

## Engine verbs the sim understands. The catalog binds buttons/taps to
## command ids; this table is the engine implementing those verbs, not a
## button binding (see design.md "UI as Data").
const VERB_KIND := {
	"move": SimCommand.Kind.MOVE,
	"patrol": SimCommand.Kind.PATROL,
	"mine": SimCommand.Kind.MINE,
	"attack": SimCommand.Kind.ATTACK_MOVE,
	"attack_move": SimCommand.Kind.ATTACK_MOVE,
	"stop": SimCommand.Kind.STOP,
	"hold": SimCommand.Kind.STOP,
}

## Player 0 is reserved for neutral/hostile-neutral map objects (§3).
const LOCAL_PLAYER := 1

var sim: GameSim
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

## Bot command sources for the AI player slots (design_m4.md §8).
var bots: Array[BotCommander] = []
var _result_layer: CanvasLayer
var _result_label: Label
var _result_shown := false

var _accumulator := 0.0
var _cmd_seq := 0
## Own main structures already evaluated for an auto location pin (entity id ->
## true), so each is considered exactly once when it completes.
var _designated_mains := {}
var _expansion_count := 0
## entity id -> UnitView, plus per-id previous/current sim positions for
## render interpolation between ticks.
var _views := {}
var _prev := {}
var _cur := {}

@onready var camera_rig: CameraRig = $CameraRig
@onready var camera: Camera3D = $CameraRig/Camera3D


func _ready() -> void:
	_show_map_select()


## Pre-match map picker (design_m5.md §4.1): choose a single-file skirmish map or
## a scenario bundle before anything is loaded. The sim stays null until a pick.
func _show_map_select() -> void:
	var ms := MapSelect.new()
	add_child(ms)
	ms.setup()
	ms.map_chosen.connect(_on_map_chosen)


func _on_map_chosen(path: String) -> void:
	map = MapLoader.load_path(path)
	if not map.ok():
		for e in map.errors:
			push_error("map: %s" % e)
		return
	world_offset = map.tiles_w / 2.0
	# Skirmish maps declare faction-agnostic start anchors and let the player pick
	# sides; scenario maps (e.g. a TD bundle) place their objects directly and go
	# straight in with their declared factions.
	if map.starts.is_empty():
		_start_match({})
	else:
		_show_faction_select()


## Pre-match faction picker (design_m4.md §13). The sim is not built until the
## player confirms; until then `sim` is null and `_process` idles.
func _show_faction_select() -> void:
	var slots: Array = []
	var ids: Array[int] = []
	for p: Dictionary in map.players:
		ids.append(int(p["id"]))
	ids.sort()
	for pid in ids:
		slots.append({"player": pid, "faction": _faction_name(pid)})
	var fs := FactionSelect.new()
	add_child(fs)
	fs.setup(slots, LOCAL_PLAYER)
	fs.confirmed.connect(_start_match)


## Build the match from the chosen factions and assemble the HUD/view. This is
## the body that used to run straight from `_ready`, now deferred behind the
## faction picker.
func _start_match(factions: Dictionary) -> void:
	# Scenario maps (no start anchors) keep their authored objects as-is; only
	# skirmish maps spawn faction loadouts at their anchors.
	if not map.starts.is_empty():
		MatchSetup.apply(map, factions)
		if not map.ok():
			for e in map.errors:
				push_error("match setup: %s" % e)
			return
	# The authoritative sim is the native C++ GDExtension (design_m5.md §2); the
	# GameSim adapter advances it and mirrors a read view for the GDScript layer.
	sim = GameSim.new()
	sim.setup(SIM_SEED, map.catalog, map, LOCAL_PLAYER)
	# Faction-aware UI: the local player's faction picks the UI layer (the
	# "UI as data" dividend — the Rebels get Crew, the mine order, worker
	# dials, the draw-wall verb; design_m4.md §13.2).
	catalog = _load_ui_for_faction(_faction_name(LOCAL_PLAYER))
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
	viewport_placement.plan_committed.connect(_on_plan_committed)
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

	controller.placement_active = viewport_placement.is_active
	controller.placement_press = viewport_placement.press
	controller.placement_drag = viewport_placement.drag
	controller.placement_release = viewport_placement.release
	controller.placement_abort = viewport_placement.abort_gesture
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

	_setup_bots()
	_setup_result_overlay()
	_setup_initial_designations()
	_sync_views()


func _process(delta: float) -> void:
	if sim == null:
		return # waiting on the faction picker; no match yet
	_accumulator += minf(delta, 0.25) # clamp away hitches/debugger pauses
	while _accumulator >= TICK_DT:
		for bot in bots:
			bot.tick()
		sim.step()
		_capture_tick()
		_drain_trigger_presentation()
		_accumulator -= TICK_DT
	_interpolate_views(_accumulator / TICK_DT)
	_check_match_over()


## Surface a map's trigger presentation (design_m5.md §3.4): messages addressed
## to the local player (or to all) become HUD status. The queue is unhashed view
## output, drained once per tick.
func _drain_trigger_presentation() -> void:
	if hud == null:
		return
	for ev: Dictionary in sim.trigger_presentation():
		if int(ev.get("kind", -1)) != 0:
			continue # 0 = message; pings (1) are not surfaced yet
		var who := int(ev.get("who", 0))
		if who == LOCAL_PLAYER or who == 0:
			hud.set_status(str(ev.get("text", "")))


# --- match: bots and the result screen (design_m4.md §7.3, §8) ----------------


## Every non-local, non-neutral player slot is driven by a BotCommander — the
## identical command pipeline a human uses (design.md "a bot is a command
## source"). Each is handed the others' main-structure positions to scout.
func _setup_bots() -> void:
	var mains := {}
	for id in sim._sorted_ids():
		var e: SimEntity = sim.entities[id]
		if e.kind == SimEntity.Kind.STRUCTURE \
				and sim.catalog.sim_of(e.type_key).get("is_main", false):
			mains[e.player] = [e.x, e.y]
	for pid in sim.players:
		if pid == 0 or pid == LOCAL_PLAYER:
			continue
		# Only players with a town hall get a bot brain; a scenario's
		# trigger-driven slot (e.g. TD creeps) has no main and is left to its
		# triggers (design_m5.md §3.5).
		if not mains.has(pid):
			continue
		var bot := BotCommander.new(sim, pid, SIM_SEED ^ (pid * 0x9E3779B1))
		for mp in mains:
			if mp != pid:
				bot.scout_hints.append(mains[mp])
		bots.append(bot)


func _setup_result_overlay() -> void:
	_result_layer = CanvasLayer.new()
	_result_layer.layer = 64
	add_child(_result_layer)
	# A full-screen dim that also swallows input, so once the match is over the
	# map no longer takes orders (the prior build had no end state — it read as
	# a freeze). The console still works behind it only via its own layer.
	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.55)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_STOP
	_result_layer.add_child(dim)
	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	_result_layer.add_child(center)
	var panel := PanelContainer.new()
	center.add_child(panel)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 16)
	panel.add_child(box)
	_result_label = Label.new()
	_result_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_result_label.add_theme_font_size_override("font_size", 40)
	box.add_child(_result_label)
	var rematch := Button.new()
	rematch.text = "Rematch"
	rematch.custom_minimum_size.y = 56
	rematch.pressed.connect(func() -> void: get_tree().reload_current_scene())
	box.add_child(rematch)
	var quit := Button.new()
	quit.text = "Exit"
	quit.custom_minimum_size.y = 56
	quit.pressed.connect(func() -> void: get_tree().quit())
	box.add_child(quit)
	_result_layer.visible = false


## Seed the Locations list with the bases that matter from the first second:
## the local player's own main structure(s) ("Home") and every opponent's start
## ("Enemy"), so the player can attack-move, build, or recall to them without
## hunting the map (playtest ask). Pure UI — designations are never sim state.
func _setup_initial_designations() -> void:
	for id in sim._sorted_ids():
		var e: SimEntity = sim.entities[id]
		if e.kind != SimEntity.Kind.STRUCTURE:
			continue
		if not sim.catalog.sim_of(e.type_key).get("is_main", false):
			continue
		if e.player == 0:
			continue # neutral map objects are never a base
		_designated_mains[id] = true
		designations.add_location(e.x, e.y,
				"Home" if e.player == LOCAL_PLAYER else "Enemy")


## Pin a freshly-built own main structure (a second stronghold / forward HQ) the
## tick it completes — but only when it's a genuine expansion, i.e. farther than
## the auto-mine radius (the resource area one depot serves) from every location
## already pinned. Rebuilding next to home, or a base in an already-marked area,
## adds no duplicate. Runs each tick off the view; designations are never sim
## state.
func _auto_designate_new_mains() -> void:
	for id in sim.entities:
		if _designated_mains.has(id):
			continue
		var e: SimEntity = sim.entities[id]
		if e.kind != SimEntity.Kind.STRUCTURE or e.player != LOCAL_PLAYER:
			continue
		if not sim.catalog.sim_of(e.type_key).get("is_main", false):
			continue
		if e.build_state != SimEntity.BuildState.COMPLETE:
			continue # wait until it actually stands
		_designated_mains[id] = true # evaluated once, added or not
		if _near_existing_location(e.x, e.y, Sim.AUTO_MINE_RADIUS):
			continue
		_expansion_count += 1
		designations.add_location(e.x, e.y, "Expansion %d" % _expansion_count)


## True if any pinned location is within `radius` (fixed world units) of (x, y).
func _near_existing_location(x: int, y: int, radius: int) -> bool:
	var r2 := Fixed.mul(radius, radius)
	for o in designations.locations():
		var loc: Dictionary = o["entry"]
		var dx: int = loc["x"] - x
		var dy: int = loc["y"] - y
		if Fixed.mul(dx, dx) + Fixed.mul(dy, dy) <= r2:
			return true
	return false


func _check_match_over() -> void:
	if _result_shown:
		return
	var res: Dictionary = sim.match_result()
	if not res["over"]:
		return
	_result_shown = true
	var won: bool = res["winner"] == LOCAL_PLAYER
	_result_label.text = "VICTORY" if won else "DEFEAT"
	_result_label.modulate = Color(0.6, 1, 0.6) if won else Color(1, 0.5, 0.5)
	_result_layer.visible = true


func _faction_name(pid: int) -> String:
	for p: Dictionary in map.players:
		if p["id"] == pid:
			return str(p["faction"])
	return ""


func _load_ui_for_faction(faction: String) -> UICatalog:
	var rebel_layer := "res://data/ui/%s_ui.json" % faction
	if faction != "" and FileAccess.file_exists(rebel_layer):
		return UICatalog.load_layers(["res://data/ui/default_ui.json", rebel_layer])
	return UICatalog.load_default()


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
	_auto_designate_new_mains()
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
		# Knowledge-gated rendering (design_m4.md §6): own entities and the
		# always-known resource nodes render; enemy entities show only when
		# the sim says we can legitimately see them — aerial capsules over
		# walls (radius-only) and ground units in unoccluded vision.
		var view: UnitView = _views[id]
		# Knowledge-gated rendering: should_render bakes own || resource || seen
		# for the local player into the per-tick snapshot (batch — no per-entity
		# boundary crossing). See GameSim / design_m4.md §6.
		view.visible = sim.should_render(e)
		# Hand the view its attack target's position so modelled units can turn
		# to face what they are hitting; facing itself is presentation-only.
		var target_pos = null
		if e.target_id != 0:
			var t: SimEntity = sim.entities.get(e.target_id)
			if t != null:
				target_pos = _sim_to_view(t)
		view.sync_state(e, capsule_time, target_pos)


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
		elif kind == SimCommand.Kind.MINE:
			# The Rebel Mine order needs the tapped resource node (§12).
			if target != null and target.entity_id > 0:
				# Tapping a worker onto an own structure that's under construction
				# (resume a paused/new build) or damaged is a build-assist, not a
				# mine: the worker walks over and works on it (design_m4.md §4.1/§4.2).
				var te: SimEntity = sim.entities.get(target.entity_id)
				if te != null and te.kind == SimEntity.Kind.STRUCTURE \
						and te.player == LOCAL_PLAYER \
						and (te.build_state != SimEntity.BuildState.COMPLETE \
							or te.hp < te.max_hp):
					_issue_command(SimCommand.Kind.REPAIR, ids,
							{"target": target.entity_id})
				else:
					params["node"] = target.entity_id
					_issue_command(kind, ids, params)
			else:
				_issue_command(SimCommand.Kind.MOVE, ids, params)
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
	var reason := sim.build_block_reason(LOCAL_PLAYER, type_key)
	if reason != "":
		hud.set_status(reason)
		return
	var builder := sim.builder_for(LOCAL_PLAYER, type_key, cx, cy)
	_issue_command(SimCommand.Kind.BUILD, [builder],
			{"type": type_key, "cx": cx, "cy": cy})
	hud.set_status("building %s" % ctx.label_of(type_key))
	# Single-build returns the console to the tab root; continuous re-arms.
	hud.console.notify_build_committed()


## The viewport planner confirmed a whole plan (design_m4.md §4.4): one BUILD
## per queued building, and one player-scoped BUILD_WALL for the drawn cells.
## Each building resolves its own builder; the wall plan picks its own workers.
func _on_plan_committed(structures: Array, wall_cells: PackedInt32Array,
		wall_type: int) -> void:
	var built := 0
	for s: Dictionary in structures:
		var type: int = s["type"]
		var builder := sim.builder_for(LOCAL_PLAYER, type, s["cx"], s["cy"])
		if builder == 0:
			continue
		_issue_command(SimCommand.Kind.BUILD, [builder],
				{"type": type, "cx": s["cx"], "cy": s["cy"]})
		built += 1
	if wall_type >= 0 and not wall_cells.is_empty():
		var cells: Array = []
		for c in wall_cells:
			cells.append(c)
		_issue_command(SimCommand.Kind.BUILD_WALL, [],
				{"type": wall_type, "cells": cells})
		hud.set_status("drawing %d wall segments" % cells.size())
	elif built > 0:
		hud.set_status("building %d" % built)
	else:
		hud.set_status("nothing could be placed there")
	hud.console.notify_build_committed()
