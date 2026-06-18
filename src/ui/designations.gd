class_name Designations
extends RefCounted
## Player-local handles on groups of units and map locations (design_m3.md
## §6.1). Deliberately NOT sim state: naming a group changes nothing in
## the world, and lockstep peers never need to agree on it. Every console
## flow that uses a designation resolves it to explicit entity ids or
## coordinates BEFORE a SimCommand is created.

signal changed

const MAX_SLOTS := 8
const GROUP_NAMES := ["Alpha", "Bravo", "Charlie", "Delta",
		"Echo", "Foxtrot", "Golf", "Hotel"]

## Slot -> entry or null. An entry:
##  {"kind": "group", "name": String, "ids": Array[int]}
##  {"kind": "location", "name": String, "x": int, "y": int}  (sim fixed)
var slots: Array = []

var _next_pin := 1


func _init() -> void:
	slots.resize(MAX_SLOTS)


## Assign unit ids to a slot (-1 = first free). Returns the slot used, or -1
## when everything is taken. `allow_empty` makes a zero-unit group (the
## Organize tab / control-button "new group" gesture) — units can be added to
## it later, and `prune` leaves a deliberately-empty group alone.
func assign_group(ids: Array[int], slot: int = -1, allow_empty: bool = false) -> int:
	if ids.is_empty() and not allow_empty:
		return -1
	if slot == -1:
		slot = _first_free()
	if slot == -1 or slot >= MAX_SLOTS:
		return -1
	slots[slot] = {"kind": "group", "name": _free_group_name(),
			"ids": ids.duplicate()}
	changed.emit()
	return slot


## Overwrite a slot's group membership with `ids`, preserving the slot's name
## when it already holds a group ("set this group = current selection"); a
## fresh name is minted for an empty slot. Returns the slot, or -1 on bad input.
func set_group(slot: int, ids: Array[int]) -> int:
	if slot < 0 or slot >= MAX_SLOTS or ids.is_empty():
		return -1
	var name := _free_group_name()
	var existing: Variant = slots[slot]
	if existing != null and existing["kind"] == "group":
		name = existing["name"]
	slots[slot] = {"kind": "group", "name": name, "ids": ids.duplicate()}
	changed.emit()
	return slot


## Pin a sim-space location. An explicit `name` labels notable pins (home base,
## enemy start); otherwise an auto-numbered "Pin N" is minted. Returns the slot,
## or -1 when full.
func add_location(x: int, y: int, name: String = "") -> int:
	var slot := _first_free()
	if slot == -1:
		return -1
	if name.is_empty():
		name = "Pin %d" % _next_pin
		_next_pin += 1
	slots[slot] = {"kind": "location", "name": name, "x": x, "y": y}
	changed.emit()
	return slot


func entry(slot: int) -> Variant:
	if slot < 0 or slot >= MAX_SLOTS:
		return null
	return slots[slot]


func clear(slot: int) -> void:
	if slot >= 0 and slot < MAX_SLOTS and slots[slot] != null:
		slots[slot] = null
		changed.emit()


## All non-empty slots, in slot order: [{slot, entry}].
func occupied() -> Array:
	var result := []
	for i in MAX_SLOTS:
		if slots[i] != null:
			result.append({"slot": i, "entry": slots[i]})
	return result


func locations() -> Array:
	return occupied().filter(func(o: Dictionary) -> bool:
		return o["entry"]["kind"] == "location")


## Drop dead unit ids (per the validity callback); a group emptied this
## way frees its slot silently (design_m3.md §6.1).
func prune(is_alive: Callable) -> void:
	var dirty := false
	for i in MAX_SLOTS:
		var e: Variant = slots[i]
		if e == null or e["kind"] != "group":
			continue
		var alive: Array[int] = []
		for id: int in e["ids"]:
			if is_alive.call(id):
				alive.append(id)
		if alive.size() != e["ids"].size():
			dirty = true
			if alive.is_empty():
				slots[i] = null
			else:
				e["ids"] = alive
	if dirty:
		changed.emit()


func _first_free() -> int:
	for i in MAX_SLOTS:
		if slots[i] == null:
			return i
	return -1


func _free_group_name() -> String:
	for name in GROUP_NAMES:
		var taken := false
		for e in slots:
			if e != null and e["name"] == name:
				taken = true
				break
		if not taken:
			return name
	return "Group"
