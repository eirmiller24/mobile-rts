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


## Per-stronghold nanomachine allocation sliders (design_m3.md §6.6).
## Sliders share the pool — pushing one past the remainder steals from
## idle first, then proportionally from the others — and ALLOCATE_ECONOMY
## fires on release, not per drag-frame.
class AllocSliders:
	extends VBoxContainer
	const CATS := ["Alloy", "Flux", "Assist"]
	var ctx: GameUIContext
	var _rows := {} # stronghold id -> {sliders: Array[HSlider], info: Label}
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
			add_child(box)
			var title := Label.new()
			title.text = "%s #%d — %d nanomachines" % [ctx.label_of(e.type_key), id, pool]
			box.add_child(title)
			var sliders: Array[HSlider] = []
			for c in 3:
				var row := HBoxContainer.new()
				row.add_theme_constant_override("separation", 10)
				box.add_child(row)
				var cat := Label.new()
				cat.text = CATS[c]
				cat.custom_minimum_size.x = 70
				row.add_child(cat)
				var slider := HSlider.new()
				slider.max_value = pool
				slider.step = 1
				slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
				slider.custom_minimum_size = Vector2(200, 36)
				slider.drag_started.connect(func() -> void: _dragging = true)
				slider.drag_ended.connect(_on_release.bind(id, c))
				row.add_child(slider)
				var val := Label.new()
				val.custom_minimum_size.x = 40
				row.add_child(val)
				sliders.append(slider)
			var info := Label.new()
			info.modulate = Color(1, 1, 1, 0.65)
			box.add_child(info)
			_rows[id] = {"sliders": sliders, "info": info, "pool": pool}

	func _refresh_values(ids: PackedInt32Array) -> void:
		for id in ids:
			if not _rows.has(id):
				continue
			var e: SimEntity = ctx.sim.entities[id]
			var row: Dictionary = _rows[id]
			for c in 3:
				var slider: HSlider = row["sliders"][c]
				slider.set_value_no_signal(e.nano_alloc[c])
				(slider.get_parent().get_child(2) as Label).text = str(e.nano_alloc[c])
			var income: Dictionary = ctx.sim.income.get(id,
					{"alloy": 0, "flux": 0, "assist_used": 0, "idle": 0})
			var idle: int = row["pool"] - e.nano_alloc[0] - e.nano_alloc[1] - e.nano_alloc[2]
			var text := "idle: %d   income: %.1f alloy/s, %.1f flux/s" % [idle,
					Fixed.to_float(income["alloy"]) * Sim.TICK_RATE,
					Fixed.to_float(income["flux"]) * Sim.TICK_RATE]
			if e.nano_alloc[0] > 0 and income["alloy"] == 0:
				text += "   ⚠ alloy allocation idle: no deposits in range"
			if e.nano_alloc[1] > 0 and income["flux"] == 0:
				text += "   ⚠ flux allocation idle: no working siphons in range"
			row["info"].text = text

	## Re-balance around the moved slider: idle absorbs first, then the
	## other two give way proportionally. Then one ALLOCATE_ECONOMY.
	func _on_release(_value_changed: bool, id: int, moved: int) -> void:
		_dragging = false
		if not _rows.has(id) or not ctx.sim.entities.has(id):
			return
		var row: Dictionary = _rows[id]
		var pool: int = row["pool"]
		var values := [0, 0, 0]
		for c in 3:
			values[c] = int((row["sliders"][c] as HSlider).value)
		var excess: int = values[0] + values[1] + values[2] - pool
		var others: Array[int] = []
		for c in 3:
			if c != moved:
				others.append(c)
		while excess > 0:
			var gave := false
			for c in others:
				if excess > 0 and values[c] > 0:
					values[c] -= 1
					excess -= 1
					gave = true
			if not gave:
				values[moved] -= excess # others empty: clamp the moved one
				excess = 0
		ctx.issue.call(SimCommand.Kind.ALLOCATE_ECONOMY, [id] as Array[int],
				{"alloy": values[0], "flux": values[1], "assist": values[2]})
		_accum = REFRESH # refresh soon to show the applied state
