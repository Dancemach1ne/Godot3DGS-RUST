class_name FreeFlyCamera
extends Camera3D

## Minimal runtime viewer controller for inspecting imported Gaussian scenes.
## W/A/S/D: move, Q/E: descend/ascend, Shift: boost, mouse: look.
@export var move_speed := 3.0
@export var mouse_sensitivity := 0.002
@export var boost_multiplier := 4.0

var _yaw := 0.0
var _pitch := 0.0

func _ready() -> void:
	_yaw = rotation.y
	_pitch = rotation.x
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.keycode == KEY_ESCAPE and event.pressed:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		return
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
		return
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		_yaw -= event.relative.x * mouse_sensitivity
		_pitch = clampf(_pitch - event.relative.y * mouse_sensitivity, -1.5, 1.5)
		rotation = Vector3(_pitch, _yaw, 0.0)

func _process(delta: float) -> void:
	var local_direction := Vector3.ZERO
	if Input.is_key_pressed(KEY_W): local_direction.z -= 1.0
	if Input.is_key_pressed(KEY_S): local_direction.z += 1.0
	if Input.is_key_pressed(KEY_A): local_direction.x -= 1.0
	if Input.is_key_pressed(KEY_D): local_direction.x += 1.0
	if Input.is_key_pressed(KEY_Q): local_direction.y -= 1.0
	if Input.is_key_pressed(KEY_E): local_direction.y += 1.0
	if local_direction.is_zero_approx(): return
	var speed := move_speed * (boost_multiplier if Input.is_key_pressed(KEY_SHIFT) else 1.0)
	global_position += global_transform.basis * local_direction.normalized() * speed * delta
