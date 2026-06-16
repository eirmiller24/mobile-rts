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
