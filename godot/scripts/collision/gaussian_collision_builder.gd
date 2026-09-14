extends RefCounted

## Godot-side adapter for the Rust collision baker. Rust returns triangle
## positions; this script owns engine Objects and attaches the physics shape.

const COLLISION_BODY_NAME := &"GaussianCollisionBody"
const COLLISION_SHAPE_NAME := &"GaussianCollisionShape"

static func generate_and_attach(
	owner: Node3D,
	resource: GaussianResource,
	voxel_size: float = 0.0,
	opacity_cutoff: float = 0.1
) -> Dictionary:
	if owner == null or not is_instance_valid(owner):
		return _failure("Collision owner is invalid.")
	if resource == null or not resource.is_valid() or resource.point_count <= 0:
		return _failure("Gaussian resource is empty or invalid.")

	var native := GdgsNative.new()
	var result: Dictionary = native.generate_collision(
		resource.point_data,
		resource.point_count,
		voxel_size,
		opacity_cutoff
	)
	if not result.get("ok", false):
		return result

	var faces: PackedVector3Array = result.get("faces", PackedVector3Array())
	if faces.is_empty() or faces.size() % 3 != 0:
		return _failure("Rust returned empty or malformed collision triangles.")

	var shape := ConcavePolygonShape3D.new()
	shape.set_faces(faces)
	shape.backface_collision = true
	if shape.get_faces().is_empty():
		return _failure("Godot could not create the concave collision shape.")

	var body := owner.get_node_or_null(NodePath(String(COLLISION_BODY_NAME))) as StaticBody3D
	if body == null:
		body = StaticBody3D.new()
		body.name = COLLISION_BODY_NAME
		owner.add_child(body)
	var collision_shape := body.get_node_or_null(NodePath(String(COLLISION_SHAPE_NAME))) as CollisionShape3D
	if collision_shape == null:
		collision_shape = CollisionShape3D.new()
		collision_shape.name = COLLISION_SHAPE_NAME
		body.add_child(collision_shape)
	collision_shape.shape = shape
	result["body"] = body
	result["shape"] = shape
	return result

static func clear(owner: Node3D) -> void:
	if owner == null:
		return
	var body := owner.get_node_or_null(NodePath(String(COLLISION_BODY_NAME)))
	if body != null:
		body.queue_free()

static func _failure(message: String) -> Dictionary:
	return {"ok": false, "message": message}
