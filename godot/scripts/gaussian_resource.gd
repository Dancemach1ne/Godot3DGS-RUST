class_name GaussianResource
extends Resource

## Shared Godot-side representation of GPU-ready Gaussian splat data.
## Rust produces the 60-float / 240-byte record layout; this resource owns the
## Godot-visible count, packed bytes, source positions and scene-space bounds.

const FLOATS_PER_SPLAT := 60
const BYTES_PER_SPLAT := FLOATS_PER_SPLAT * 4

@export var point_count := 0
@export var point_data := PackedByteArray()
@export var positions := PackedVector3Array()
@export var aabb := AABB()

func is_valid() -> bool:
	return (
		point_count >= 0
		and point_data.size() == point_count * BYTES_PER_SPLAT
		and positions.size() == point_count
	)

## A deterministic fixture used only to validate the Godot-side contract.
func configure_single_test_splat() -> void:
	point_count = 1
	point_data.resize(BYTES_PER_SPLAT)
	positions = PackedVector3Array([Vector3(1.0, 2.0, 3.0)])
	aabb = AABB(Vector3(1.0, 2.0, 3.0), Vector3.ZERO)
