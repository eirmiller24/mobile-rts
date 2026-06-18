class_name ConsoleWidgets
## Console widget implementations (design_m3.md §6.7): each is an
## engine-coded Control *parameterized by data* — which catalog kinds it
## lists and where it links come from the UI catalog, never from code.
## All of them poll the sim on a short cadence and rebuild only when
## their content signature changes (so a button is never yanked out from
## under a finger).

const REFRESH := 0.4


## Grid of buildable structures from the player's build abilities; tapping
## one arms the placement flow (design_m3.md §6.3, screen 1).
class StructureGrid:
	extends GridContainer
	var ctx: GameUIContext
	var on_pick: Callable
	var _sig := ""
	var _accum := 999.0

	func _init(p_ctx: GameUIContext, p_on_pick: Callable) -> void:
		ctx = p_ctx
		on_pick = p_on_pick
		columns = 3

	func _process(delta: float) -> void:
		if not is_visible_in_tree():
			return
		_accum += delta
		if _accum < REFRESH:
			return
		_accum = 0.0
		var types := ctx.sim.buildable_structures(ctx.local_player)
		var sig := ""
		for t in types:
			sig += "%d:%d;" % [t, int(ctx.affordable(t))]
		if sig == _sig:
			return
		_sig = sig
		for child in get_children():
			child.queue_free()
		if types.is_empty():
			var label := Label.new()
			label.text = "Nothing can build right now."
			add_child(label)
		for t in types:
			var btn := Button.new()
			btn.custom_minimum_size = Vector2(150, 64)
			btn.text = "%s\n%s" % [ctx.label_of(t), ctx.cost_text(t)]
			btn.disabled = not ctx.affordable(t)
			btn.pressed.connect(on_pick.bind(t))
			add_child(btn)


## Grid of trainable units; tap = TRAIN at the eligible structure with the
## shortest queue — the UI picks, the command carries the explicit id
## (design_m3.md §6.5).
class UnitGrid:
	extends GridContainer
	var ctx: GameUIContext
	var _sig := ""
	var _accum := 999.0

	func _init(p_ctx: GameUIContext) -> void:
		ctx = p_ctx
		columns = 3

	func _process(delta: float) -> void:
		if not is_visible_in_tree():
			return
		_accum += delta
		if _accum < REFRESH:
			return
		_accum = 0.0
		var types := ctx.sim.trainable_units(ctx.local_player)
		var sig := ""
		for t in types:
			sig += "%d:%d;" % [t, int(ctx.affordable(t))]
		if sig == _sig:
			return
		_sig = sig
		for child in get_children():
			child.queue_free()
		if types.is_empty():
			var label := Label.new()
			label.text = "No production structures yet."
			add_child(label)
		for t in types:
			var btn := Button.new()
			btn.custom_minimum_size = Vector2(150, 64)
			btn.text = "%s\n%s" % [ctx.label_of(t), ctx.cost_text(t)]
			btn.disabled = not ctx.affordable(t)
			btn.pressed.connect(_train.bind(t))
			add_child(btn)

	func _train(type_key: int) -> void:
		var sid := ctx.sim.train_structure_for(ctx.local_player, type_key)
		if sid == 0:
			ctx.status.call("no structure can train that")
			return
		var bw := ctx.sim.bandwidth_of(ctx.local_player)
		var need: int = ctx.sim.catalog.sim_of(type_key)["bandwidth"]
		if bw["used"] + need > bw["provided"]:
			ctx.status.call("bandwidth full (%d/%d)" % [bw["used"], bw["provided"]])
			return
		ctx.issue.call(SimCommand.Kind.TRAIN, [sid] as Array[int], {"type": type_key})


## Per-structure training queues with tap-to-cancel (design_m3.md §6.5).
class QueueStrip:
	extends VBoxContainer
	var ctx: GameUIContext
	var _sig := ""
	var _accum := 999.0

	func _init(p_ctx: GameUIContext) -> void:
		ctx = p_ctx
		add_theme_constant_override("separation", 6)

	func _process(delta: float) -> void:
		if not is_visible_in_tree():
			return
		_accum += delta
		if _accum < REFRESH:
			return
		_accum = 0.0
		var queues := ctx.sim.training_queues(ctx.local_player)
		var sig := ""
		for q: Dictionary in queues:
			sig += "%d=%s;" % [q["id"], q["queue"]]
		if sig == _sig:
			return
		_sig = sig
		for child in get_children():
			child.queue_free()
		for q: Dictionary in queues:
			var row := HBoxContainer.new()
			row.add_theme_constant_override("separation", 6)
			add_child(row)
			var name_label := Label.new()
			name_label.text = "%s #%d:" % [ctx.label_of(q["type_key"]), q["id"]]
			row.add_child(name_label)
			if q["queue"].is_empty():
				var idle := Label.new()
				idle.text = "idle"
				idle.modulate = Color(1, 1, 1, 0.5)
				row.add_child(idle)
			for i in q["queue"].size():
				var item := Button.new()
				item.text = "%s ✕" % ctx.label_of(q["queue"][i])
				item.custom_minimum_size.y = 40
				item.pressed.connect(_cancel.bind(q["id"], i))
				row.add_child(item)

	func _cancel(structure_id: int, index: int) -> void:
		ctx.issue.call(SimCommand.Kind.CANCEL,
				[structure_id] as Array[int], {"index": index})


## Per-stronghold nanomachine allocation (design_m3.md §6.6), expressed as
## two fractions rather than three raw counts: one slider splits the pool
## between mining and repair, the other splits the mining share between
## alloy and flux. The sim still stores three explicit counts — this widget
## just converts. ALLOCATE_ECONOMY fires on release, not per drag-frame.
class AllocSliders:
	extends VBoxContainer
	var ctx: GameUIContext
	var _rows := {} # stronghold id -> {split, focus: HSlider, info, title, pool}
	var _sig := ""
	var _accum := 999.0
	var _dragging := false

	func _init(p_ctx: GameUIContext) -> void:
		ctx = p_ctx
		add_theme_constant_override("separation", 14)

	func _process(delta: float) -> void:
		if not is_visible_in_tree() or _dragging:
			return
		_accum += delta
		if _accum < REFRESH:
			return
		_accum = 0.0
		var ids := ctx.sim.stronghold_ids(ctx.local_player)
		var sig := str(ids)
		if sig != _sig:
			_sig = sig
			_rebuild(ids)
		_refresh_values(ids)

	func _rebuild(ids: PackedInt32Array) -> void:
		for child in get_children():
			child.queue_free()
		_rows.clear()
		if ids.is_empty():
			var label := Label.new()
			label.text = "No strongholds."
			add_child(label)
			return
		for id in ids:
			var e: SimEntity = ctx.sim.entities[id]
			var pool: int = ctx.sim.catalog.sim_of(e.type_key)["nano_pool"]
			var box := VBoxContainer.new()
			box.add_theme_constant_override("separation", 6)
			add_child(box)
			var title := Label.new()
			box.add_child(title)
			# Slider value = share of the right-hand label, so the thumb sits
			# under the option it favors.
			var split := _make_slider(box, id, "Mine ◂▸ Repair")
			var focus := _make_slider(box, id, "Alloy ◂▸ Flux")
			var info := Label.new()
			info.modulate = Color(1, 1, 1, 0.65)
			info.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
			box.add_child(info)
			_rows[id] = {"split": split, "focus": focus, "info": info,
					"title": title, "pool": pool}

	func _make_slider(box: VBoxContainer, id: int, caption: String) -> HSlider:
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 10)
		box.add_child(row)
		var cap := Label.new()
		cap.text = caption
		cap.custom_minimum_size.x = 120
		row.add_child(cap)
		var slider := HSlider.new()
		slider.min_value = 0
		slider.max_value = 100
		slider.step = 1
		slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		slider.custom_minimum_size = Vector2(200, 44)
		slider.drag_started.connect(func() -> void: _dragging = true)
		slider.drag_ended.connect(_on_release.bind(id))
		row.add_child(slider)
		return slider

	func _refresh_values(ids: PackedInt32Array) -> void:
		for id in ids:
			if not _rows.has(id):
				continue
			var e: SimEntity = ctx.sim.entities[id]
			var row: Dictionary = _rows[id]
			var pool: int = row["pool"]
			var alloc := e.nano_alloc
			var assist: int = alloc[2]
			var resource: int = alloc[0] + alloc[1]
			var repair_pct := 0 if pool <= 0 else roundi(assist * 100.0 / pool)
			var flux_pct := 50 if resource <= 0 else roundi(alloc[1] * 100.0 / resource)
			(row["split"] as HSlider).set_value_no_signal(repair_pct)
			(row["focus"] as HSlider).set_value_no_signal(flux_pct)
			row["title"].text = "%s #%d — %d nanomachines" % [
					ctx.label_of(e.type_key), id, pool]
			var income: Dictionary = ctx.sim.income.get(id,
					{"alloy": 0, "flux": 0, "idle_assist": 0})
			var text := "mine %d (%d alloy / %d flux)   repair %d" % [
					resource, alloc[0], alloc[1], assist]
			var idle_assist: int = income.get("idle_assist", 0)
			if idle_assist > 0:
				text += "   ↩ %d idle repair → mining" % idle_assist
			text += "\nincome: %.1f alloy/s, %.1f flux/s" % [
					Fixed.to_float(income["alloy"]) * Sim.TICK_RATE,
					Fixed.to_float(income["flux"]) * Sim.TICK_RATE]
			if alloc[0] > 0 and income["alloy"] == 0:
				text += "   ⚠ no alloy deposits in range"
			if alloc[1] > 0 and income["flux"] == 0:
				text += "   ⚠ no working siphons in range"
			row["info"].text = text

	## Convert the two fractions back into three counts that exactly sum to
	## the pool, then fire one ALLOCATE_ECONOMY.
	func _on_release(_value_changed: bool, id: int) -> void:
		_dragging = false
		if not _rows.has(id) or not ctx.sim.entities.has(id):
			return
		var row: Dictionary = _rows[id]
		var pool: int = row["pool"]
		var repair_pct := int((row["split"] as HSlider).value)
		var flux_pct := int((row["focus"] as HSlider).value)
		var assist := roundi(pool * repair_pct / 100.0)
		var resource := pool - assist
		var flux := roundi(resource * flux_pct / 100.0)
		var alloy := resource - flux
		ctx.issue.call(SimCommand.Kind.ALLOCATE_ECONOMY, [id] as Array[int],
				{"alloy": alloy, "flux": flux, "assist": assist})
		_accum = REFRESH # refresh soon to show the applied state


## Organize tab roster (design.md "Organize"): a button that snapshots the
## current viewport selection into a new control group, plus a read-only list
## of every group with each member's live health. Group assign/recall now lives
## here and on the top-bar chips; the control button only edits the selection.
## Display-only for now — swapping units between groups lands later.
class GroupRoster:
	extends VBoxContainer
	var ctx: GameUIContext
	var _sig := ""
	var _accum := 999.0

	func _init(p_ctx: GameUIContext) -> void:
		ctx = p_ctx
		add_theme_constant_override("separation", 12)
		# Group membership changes off-cadence (assign/recall, dead-unit prune);
		# refresh promptly when it does.
		ctx.designations.changed.connect(func() -> void: _accum = REFRESH)

	func _process(delta: float) -> void:
		if not is_visible_in_tree():
			return
		_accum += delta
		if _accum < REFRESH:
			return
		_accum = 0.0
		var groups := _groups()
		var sig := ""
		for g: Dictionary in groups:
			sig += "%d:%s:[" % [g["slot"], g["entry"]["name"]]
			for id: int in g["entry"]["ids"]:
				var e: SimEntity = ctx.sim.entities.get(id)
				sig += "%d=%d/%d," % [id, e.hp if e else 0, e.max_hp if e else 0]
			sig += "];"
		if sig == _sig:
			return
		_sig = sig
		_rebuild(groups)

	func _rebuild(groups: Array) -> void:
		for child in get_children():
			child.queue_free()
		# Always enabled: with a selection it snapshots those units, otherwise
		# it makes an empty group to fill later (control button + chip, or the
		# control-group gesture).
		var create := Button.new()
		create.text = "New control group"
		create.custom_minimum_size.y = 52.0
		create.pressed.connect(_on_create)
		add_child(create)
		if groups.is_empty():
			var empty := Label.new()
			empty.text = "No control groups yet. Tap New control group to make one (empty if nothing is selected)."
			empty.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
			empty.modulate = Color(1, 1, 1, 0.6)
			add_child(empty)
			return
		for g: Dictionary in groups:
			var e: Dictionary = g["entry"]
			var header := Label.new()
			header.text = "%s (%d)" % [e["name"], e["ids"].size()]
			header.add_theme_font_size_override("font_size", 18)
			header.add_theme_color_override("font_color", Color(0.8, 1.0, 0.85))
			add_child(header)
			for id: int in e["ids"]:
				add_child(_member_row(id))

	func _member_row(id: int) -> Control:
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 8)
		var ent: SimEntity = ctx.sim.entities.get(id)
		var name_label := Label.new()
		name_label.custom_minimum_size.x = 150
		name_label.text = "%s #%d" % [ctx.label_of(ent.type_key), id] if ent \
				else "#%d (lost)" % id
		row.add_child(name_label)
		var bar := ProgressBar.new()
		bar.custom_minimum_size = Vector2(160, 22)
		bar.min_value = 0
		bar.max_value = ent.max_hp if ent else 1
		bar.value = ent.hp if ent else 0
		bar.show_percentage = false
		row.add_child(bar)
		var hp_label := Label.new()
		hp_label.text = "%d/%d" % [ent.hp, ent.max_hp] if ent else "—"
		hp_label.modulate = Color(1, 1, 1, 0.7)
		row.add_child(hp_label)
		return row

	func _on_create() -> void:
		var ids: Array[int] = _selection()
		var slot := ctx.designations.assign_group(ids, -1, true)
		if ctx.status.is_valid():
			ctx.status.call("%s = %d units"
					% [ctx.designations.entry(slot)["name"], ids.size()] if slot != -1
					else "no free group slots")

	func _groups() -> Array:
		return ctx.designations.occupied().filter(func(o: Dictionary) -> bool:
			return o["entry"]["kind"] == "group")

	func _selection() -> Array[int]:
		return ctx.selected_ids.call() if ctx.selected_ids.is_valid() else [] as Array[int]


## A window onto the auto pool's worker states (design_m4.md §3.2): one bar
## over N workers with three handles — a center Alloy/Flux split and a per-side
## build/repair draft handle. Discrete, snapping to whole workers; the center
## handle wins a coincident touch. Pure view: it reads the live state counts
## and emits handle positions, never holding a ratio of its own.
class WorkerSplitBar:
	extends Control
	# n = pool size; c = alloy-side count; l = alloy_build; fb = flux_build.
	# Layout: [alloy+build (l) | alloy (c-l) ‖ flux | flux+build (fb)].
	var n := 0
	var c := 0
	var l := 0
	var fb := 0
	var dragging := false
	var on_release: Callable
	var _grab := -1   # 0 left, 1 center, 2 right; -1 none
	const ALLOY := Color(0.85, 0.6, 0.25)
	const FLUX := Color(0.3, 0.7, 0.85)

	func _init() -> void:
		custom_minimum_size = Vector2(220, 60)

	func set_model(p_n: int, p_c: int, p_l: int, p_fb: int) -> void:
		if dragging:
			return
		n = p_n
		c = clampi(p_c, 0, n)
		l = clampi(p_l, 0, c)
		fb = clampi(p_fb, 0, n - c)
		queue_redraw()

	# Leave ~15% padding each side so the live edge of the bar never sits at the
	# screen edge, where a thumb drag can trigger phone system gestures.
	func _margin() -> float:
		return maxf(18.0, size.x * 0.15)

	func _usable() -> float:
		return maxf(1.0, size.x - 2.0 * _margin())

	func _pos_x(pos: int) -> float:
		if n <= 0:
			return _margin()
		return _margin() + _usable() * float(pos) / float(n)

	func _x_pos(x: float) -> int:
		if n <= 0:
			return 0
		return clampi(roundi((x - _margin()) / _usable() * float(n)), 0, n)

	func _gui_input(event: InputEvent) -> void:
		if n <= 0:
			return
		if event is InputEventMouseButton:
			if event.button_index == MOUSE_BUTTON_LEFT:
				if event.pressed:
					_begin(event.position.x)
				elif _grab != -1:
					_grab = -1
					dragging = false
					if on_release.is_valid():
						on_release.call()
			accept_event()
		elif event is InputEventMouseMotion and _grab != -1:
			_move(event.position.x)
			accept_event()

	func _begin(x: float) -> void:
		var pos := _x_pos(x)
		var dl := absi(pos - l)
		var dc := absi(pos - c)
		var dr := absi(pos - (n - fb))
		if dc <= dl and dc <= dr:
			_grab = 1   # center wins coincident touch (§3.2)
		elif dl <= dr:
			_grab = 0
		else:
			_grab = 2
		dragging = true
		_move(x)

	func _move(x: float) -> void:
		var pos := _x_pos(x)
		match _grab:
			1:  # center split — build counts stay sticky, clamped to each side
				c = clampi(pos, 0, n)
				l = mini(l, c)
				fb = mini(fb, n - c)
			0:  # alloy-side build draft (edge → center)
				l = clampi(pos, 0, c)
			2:  # flux-side build draft (center → edge)
				fb = clampi(n - pos, 0, n - c)
		queue_redraw()

	func _draw() -> void:
		var y := size.y * 0.5
		var h := 12.0
		if n <= 0:
			draw_string(get_theme_default_font(), Vector2(_margin(), y),
					"no workers in the auto pool", HORIZONTAL_ALIGNMENT_LEFT,
					-1, 16, Color(1, 1, 1, 0.5))
			return
		var r := n - fb
		# Region fills: build regions are the dimmer shade of their side.
		_band(_margin(), _pos_x(l), y, h, ALLOY.darkened(0.35))
		_band(_pos_x(l), _pos_x(c), y, h, ALLOY)
		_band(_pos_x(c), _pos_x(r), y, h, FLUX)
		_band(_pos_x(r), _pos_x(n), y, h, FLUX.darkened(0.35))
		# Handles: side handles small, center large.
		_handle(_pos_x(l), y, 6.0, 22.0)
		_handle(_pos_x(r), y, 6.0, 22.0)
		_handle(_pos_x(c), y, 10.0, 30.0)
		# Counts above the bar: total mining each side, with the build/repair
		# draftable count of that side in parentheses (e.g. "Alloy 2 (1 build)").
		var font := get_theme_default_font()
		var txt := "Alloy %d (%d build)   Flux %d (%d build)" % [c, l, n - c, fb]
		draw_string(font, Vector2(_margin(), y - 20.0), txt,
				HORIZONTAL_ALIGNMENT_LEFT, -1, 15, Color(1, 1, 1, 0.8))

	func _band(x0: float, x1: float, y: float, h: float, col: Color) -> void:
		if x1 <= x0:
			return
		draw_rect(Rect2(x0, y - h * 0.5, x1 - x0, h), col)

	func _handle(x: float, y: float, half_w: float, hgt: float) -> void:
		draw_rect(Rect2(x - half_w, y - hgt * 0.5, half_w * 2.0, hgt),
				Color(0.95, 0.95, 0.95))


## The Rebel Economy tab (design_m4.md §13.2, §3.2 playtest): ONE worker slider
## per stronghold (the Rebel analog of AllocSliders' per-stronghold nano rows),
## each with its own keep-target stepper and Alloy/Flux/build split. The slider
## range is the stronghold's TARGET headcount, not its live count, so losing
## workers never moves the allocation — auto-replace just refills toward it. Plus
## one global auto-repair toggle. One SET_ECONOMY per change, scoped to the depot.
class WorkerDials:
	extends VBoxContainer
	var ctx: GameUIContext
	var _rows := {}  # depot id -> {title: Label, bar: WorkerSplitBar}
	var _auto := CheckButton.new()
	var _info := Label.new()
	var _sig := ""
	var _accum := 999.0

	func _init(p_ctx: GameUIContext) -> void:
		ctx = p_ctx
		add_theme_constant_override("separation", 14)
		_auto.text = "Auto-repair"
		_auto.toggled.connect(func(on: bool) -> void:
			ctx.issue.call(SimCommand.Kind.SET_ECONOMY, [] as Array[int],
					{"auto_repair": on})
			_accum = REFRESH)
		_info.modulate = Color(1, 1, 1, 0.65)
		_info.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART

	func _process(delta: float) -> void:
		if not is_visible_in_tree():
			return
		_accum += delta
		if _accum < REFRESH:
			return
		_accum = 0.0
		var ids := ctx.sim.depot_ids(ctx.local_player)
		var sig := str(ids)
		if sig != _sig:
			_sig = sig
			_rebuild(ids)
		_refresh(ids)

	func _rebuild(ids: PackedInt32Array) -> void:
		for c in get_children():
			c.queue_free()
		_rows.clear()
		if ids.is_empty():
			var lbl := Label.new()
			lbl.text = "No strongholds."
			add_child(lbl)
			return
		for did in ids:
			var box := VBoxContainer.new()
			box.add_theme_constant_override("separation", 6)
			add_child(box)
			var head := HBoxContainer.new()
			head.add_theme_constant_override("separation", 10)
			box.add_child(head)
			var minus := Button.new()
			minus.text = "−"
			minus.custom_minimum_size = Vector2(48, 44)
			minus.pressed.connect(_emit_target.bind(did, -1))
			head.add_child(minus)
			var title := Label.new()
			title.custom_minimum_size.x = 220
			head.add_child(title)
			var plus := Button.new()
			plus.text = "+"
			plus.custom_minimum_size = Vector2(48, 44)
			plus.pressed.connect(_emit_target.bind(did, 1))
			head.add_child(plus)
			var bar := WorkerSplitBar.new()
			bar.on_release = _emit_split.bind(did)
			box.add_child(bar)
			_rows[did] = {"title": title, "bar": bar}
		add_child(_auto)   # global controls below the per-stronghold rows
		add_child(_info)

	func _refresh(ids: PackedInt32Array) -> void:
		var p: SimPlayer = ctx.sim.players.get(ctx.local_player)
		if p != null:
			_auto.set_pressed_no_signal(p.auto_repair)
		for did in ids:
			if not _rows.has(did):
				continue
			var eco := ctx.sim.depot_economy(did)
			if eco.is_empty():
				continue
			var row: Dictionary = _rows[did]
			(row["title"] as Label).text = "Stronghold #%d — keep %d (%d live)" \
					% [did, eco["target"], eco["live"]]
			(row["bar"] as WorkerSplitBar).set_model(eco["target"], eco["alloy"],
					eco["alloy_build"], eco["flux_build"])
		var res := ctx.sim.resources_of(ctx.local_player)
		_info.text = "%d alloy / %d flux" % [res["alloy"], res["flux"]]

	func _emit_target(did: int, d: int) -> void:
		var eco := ctx.sim.depot_economy(did)
		if eco.is_empty():
			return
		ctx.issue.call(SimCommand.Kind.SET_ECONOMY, [did] as Array[int],
				{"worker_target": maxi(0, int(eco["target"]) + d)})
		_accum = REFRESH

	func _emit_split(did: int) -> void:
		if not _rows.has(did):
			return
		var bar: WorkerSplitBar = _rows[did]["bar"]
		ctx.issue.call(SimCommand.Kind.SET_ECONOMY, [did] as Array[int], {
			"alloy_side": bar.c,
			"alloy_build": bar.l,
			"flux_build": bar.fb,
		})
		_accum = REFRESH


## The Tactics tab (design_m4.md §13.1): stance buttons plus focus_fire /
## hold_position toggles, acting on the current selection, emitting SET_TACTIC.
class StancePicker:
	extends VBoxContainer
	var ctx: GameUIContext
	const STANCES := [
		[CatalogSchema.Stance.BALANCED, "Balanced"],
		[CatalogSchema.Stance.DEFENSIVE, "Defensive"],
		[CatalogSchema.Stance.RECKLESS, "Reckless"],
		[CatalogSchema.Stance.SKIRMISH, "Skirmish"],
	]
	var _focus := CheckButton.new()
	var _hold := CheckButton.new()

	func _init(p_ctx: GameUIContext) -> void:
		ctx = p_ctx
		add_theme_constant_override("separation", 10)
		var grid := GridContainer.new()
		grid.columns = 2
		grid.add_theme_constant_override("h_separation", 8)
		grid.add_theme_constant_override("v_separation", 8)
		add_child(grid)
		for s in STANCES:
			var btn := Button.new()
			btn.text = s[1]
			btn.custom_minimum_size.y = 52
			btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			btn.pressed.connect(_set_stance.bind(s[0]))
			grid.add_child(btn)
		_focus.text = "Focus fire"
		_focus.toggled.connect(func(_o: bool) -> void: _emit_flags())
		add_child(_focus)
		_hold.text = "Hold position"
		_hold.toggled.connect(func(_o: bool) -> void: _emit_flags())
		add_child(_hold)
		var hint := Label.new()
		hint.modulate = Color(1, 1, 1, 0.6)
		hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		hint.text = "Applies to the current selection. Defensive holds an anchor; reckless chases; skirmish keeps advancing and fires opportunistically."
		add_child(hint)

	func _selection() -> Array[int]:
		return ctx.selected_ids.call() if ctx.selected_ids.is_valid() else [] as Array[int]

	func _set_stance(stance: int) -> void:
		var ids := _selection()
		if ids.is_empty():
			return
		ctx.issue.call(SimCommand.Kind.SET_TACTIC, ids, {"stance": stance})

	func _emit_flags() -> void:
		var ids := _selection()
		if ids.is_empty():
			return
		var flags := 0
		if _focus.button_pressed:
			flags |= CatalogSchema.TacticFlag.FOCUS_FIRE
		if _hold.button_pressed:
			flags |= CatalogSchema.TacticFlag.HOLD_POSITION
		ctx.issue.call(SimCommand.Kind.SET_TACTIC, ids, {"flags": flags})


## Build-at-a-location picker (design.md "The Command Console"): the saved
## locations on the left, the pick-minimap on the right. Tapping a location
## previews the building auto-placed at that base; tapping the map previews it
## at that point. Engine-coded layout, but every target is live designation
## data and the minimap mode is catalog data — no binding is hardcoded here.
class BuildTargets:
	extends HBoxContainer
	var ctx: GameUIContext
	## func(slot: int) — preview a build at the chosen location designation.
	var on_location: Callable
	## func(x: int, y: int) — preview a build at a bare map point (sim fixed).
	var on_point: Callable
	var _list: VBoxContainer
	var _sig := ""
	var _accum := 999.0

	func _init(p_ctx: GameUIContext, p_on_location: Callable,
			p_on_point: Callable, minimap_mode: String) -> void:
		ctx = p_ctx
		on_location = p_on_location
		on_point = p_on_point
		add_theme_constant_override("separation", 12)
		size_flags_horizontal = Control.SIZE_EXPAND_FILL
		# Two equal columns, each centering its own content: the location list on
		# the left, the minimap on the right — so neither is smooshed to one edge.
		var left := VBoxContainer.new()
		left.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		_list = VBoxContainer.new()
		_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		_list.add_theme_constant_override("separation", 6)
		left.add_child(_list)
		add_child(left)
		var right := CenterContainer.new()
		right.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var mini := MinimapView.new()
		mini.sim = ctx.sim
		mini.local_player = ctx.local_player
		mini.designations = ctx.designations
		mini.mode = MinimapView.Mode.PICK if minimap_mode == "pick" \
				else MinimapView.Mode.JUMP
		mini.custom_minimum_size = Vector2(300, 300)
		mini.pin_tapped.connect(on_location)
		mini.point_tapped.connect(on_point)
		right.add_child(mini)
		add_child(right)

	func _process(delta: float) -> void:
		if not is_visible_in_tree():
			return
		_accum += delta
		if _accum < REFRESH:
			return
		_accum = 0.0
		var locs := ctx.designations.locations()
		var sig := ""
		for o: Dictionary in locs:
			sig += "%d:%s;" % [o["slot"], o["entry"]["name"]]
		if sig == _sig:
			return
		_sig = sig
		for child in _list.get_children():
			child.queue_free()
		if locs.is_empty():
			var lbl := Label.new()
			lbl.text = "No saved locations.\nLong-press the map to pin one, or tap the minimap."
			lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
			lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
			lbl.modulate = Color(1, 1, 1, 0.7)
			_list.add_child(lbl)
			return
		for o: Dictionary in locs:
			var btn := Button.new()
			btn.custom_minimum_size = Vector2(220, 48)
			btn.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
			btn.text = o["entry"]["name"]
			btn.pressed.connect(on_location.bind(o["slot"]))
			_list.add_child(btn)
