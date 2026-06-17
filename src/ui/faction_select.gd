class_name FactionSelect
extends CanvasLayer
## Pre-match setup screen (design_m4.md §13): the human picks their own
## faction and assigns each bot slot a faction before the sim is built. Mirror
## matchups (hive v hive, rebels v rebels) are allowed. It emits the chosen
## pid -> faction map and frees itself; the game root then hands that to
## MatchSetup. Purely view-side — it touches no sim state.

signal confirmed(factions: Dictionary)

## pid -> faction string. Seeded from the map defaults, edited by the buttons.
var _picks := {}
## pid -> { faction -> Button } so a pick can restyle its row.
var _buttons := {}
var _local_player := 1


## `slots` is an ordered list of { player: int, faction: String } (the seed
## faction per slot). `local_player` marks which slot is "You".
func setup(slots: Array, local_player: int) -> void:
	_local_player = local_player
	layer = 80

	var dim := ColorRect.new()
	dim.color = Color(0.04, 0.05, 0.07, 0.96)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(dim)

	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(center)

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 20)
	center.add_child(box)

	var title := Label.new()
	title.text = "Choose Factions"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 36)
	box.add_child(title)

	for slot: Dictionary in slots:
		var pid := int(slot["player"])
		_picks[pid] = str(slot["faction"])
		box.add_child(_build_row(pid))

	var start := Button.new()
	start.text = "Start Match"
	start.custom_minimum_size = Vector2(280, 64)
	start.add_theme_font_size_override("font_size", 24)
	start.pressed.connect(_on_start)
	box.add_child(start)


func _build_row(pid: int) -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)

	var who := Label.new()
	who.text = "You" if pid == _local_player else "Bot %d" % pid
	who.custom_minimum_size.x = 120
	who.add_theme_font_size_override("font_size", 24)
	row.add_child(who)

	_buttons[pid] = {}
	for faction: String in MatchSetup.playable_factions():
		var b := Button.new()
		b.toggle_mode = true
		b.text = faction.capitalize()
		b.custom_minimum_size = Vector2(160, 56)
		b.pressed.connect(_on_pick.bind(pid, faction))
		row.add_child(b)
		_buttons[pid][faction] = b
	_restyle(pid)
	return row


func _on_pick(pid: int, faction: String) -> void:
	_picks[pid] = faction
	_restyle(pid)


func _restyle(pid: int) -> void:
	for faction: String in _buttons[pid]:
		var b: Button = _buttons[pid][faction]
		b.button_pressed = faction == _picks[pid]


func _on_start() -> void:
	var result := _picks.duplicate()
	confirmed.emit(result)
	queue_free()
