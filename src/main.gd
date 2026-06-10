extends Node3D
## Game root: owns the sim and drives it at a fixed tick rate from render
## time. The view layer (camera, future unit visuals/UI) lives under this
## node and reads sim state; it never mutates it except through commands.

const TICK_DT := 1.0 / Sim.TICK_RATE

var sim: Sim
var _accumulator := 0.0


func _ready() -> void:
	sim = Sim.new(0xC0FFEE)


func _process(delta: float) -> void:
	_accumulator += minf(delta, 0.25) # clamp away hitches/debugger pauses
	while _accumulator >= TICK_DT:
		sim.step()
		_accumulator -= TICK_DT
