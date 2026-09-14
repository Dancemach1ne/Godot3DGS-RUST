extends Node

const GaussianResourceScript = preload("res://scripts/gaussian_resource.gd")
const GaussianSplatRasterScript = preload("res://scripts/raster/gaussian_splat_raster.gd")
const GaussianRenderManagerScript = preload("res://scripts/compute/full/gaussian_render_manager.gd")
const GaussianComputeNodeScript = preload("res://scripts/compute/full/gaussian_compute_node.gd")
const GaussianCompositorEffectScript = preload("res://scripts/compute/full/gaussian_compositor_effect.gd")
const FreeFlyCameraScript = preload("res://scripts/free_fly_camera.gd")
const IMPORTED_TEST_PLY_PATH := "res://assets/point_cloud.ply"

@export_group("Collision")
@export var generate_collision_on_start := false
@export_range(0.0, 10.0, 0.001, "or_greater") var collision_voxel_size := 0.0
@export_range(0.001, 0.999, 0.001) var collision_opacity_cutoff := 0.1

@export_group("Collision Test Cube")
@export var spawn_collision_test_cube := true
@export var collision_test_cube_position := Vector3(0.0, 3.0, 0.0)
@export_range(0.1, 10.0, 0.1, "or_greater") var collision_test_cube_size := 1.0

@export_group("Rendering Diagnostics")
## Direct Texture was useful while bringing up Compute, but it covers normal
## Godot meshes. Keep it optional so the collision cube can be seen.
@export var direct_texture_diagnostic_mode := false

func _ready() -> void:
	var native := GdgsNative.new()
	print("[Godot3DGS-RUST] ", native.get_build_info())
	print("[Godot3DGS-RUST] native sum check: ", native.sum_i64(20, 22))
	assert(native.splat_floats_per_record() == GaussianResourceScript.FLOATS_PER_SPLAT)
	assert(native.splat_bytes_per_record() == GaussianResourceScript.BYTES_PER_SPLAT)
	var resource = GaussianResourceScript.new()
	resource.configure_single_test_splat()
	assert(resource.is_valid())
	print("[Godot3DGS-RUST] ", native.test_splat_summary())
	print("[Godot3DGS-RUST] Godot GaussianResource contract validated")
	var fixture_path := _write_milestone_2_fixture()
	var decode_result: Dictionary = native.decode_standard_ply(fixture_path)
	assert(decode_result.get("ok", false), str(decode_result.get("message", "Rust PLY decode failed")))
	assert(int(decode_result["point_count"]) == 2)
	assert((decode_result["point_data"] as PackedByteArray).size() == 2 * GaussianResourceScript.BYTES_PER_SPLAT)
	var decoded_positions: PackedVector3Array = decode_result["positions"]
	assert(decoded_positions == PackedVector3Array([Vector3(-1.0, -1.0, -1.0), Vector3(1.0, 1.0, 1.0)]))
	print("[Godot3DGS-RUST] Rust standard-PLY decode validated")
	var collision_result: Dictionary = native.generate_collision(
		decode_result["point_data"],
		int(decode_result["point_count"]),
		0.02,
		0.1
	)
	assert(collision_result.get("ok", false), str(collision_result.get("message", "Rust collision bake failed")))
	var collision_faces: PackedVector3Array = collision_result.get("faces", PackedVector3Array())
	assert(not collision_faces.is_empty() and collision_faces.size() % 3 == 0)
	print("[Godot3DGS-RUST] Rust collision bridge validated: %d triangles" % (collision_faces.size() / 3))
	_show_compute_fixture(decode_result)

func _show_raster_fixture(decode_result: Dictionary) -> void:
	var resource := GaussianResourceScript.new()
	resource.point_count = int(decode_result["point_count"])
	resource.point_data = decode_result["point_data"]
	resource.positions = decode_result["positions"]
	resource.aabb = AABB(Vector3(-1.0, -1.0, -1.0), Vector3(2.0, 2.0, 2.0))
	var raster := GaussianSplatRasterScript.new()
	raster.gaussian = resource
	add_child(raster)
	var camera := Camera3D.new()
	camera.position = Vector3(0.0, 0.0, 6.0)
	camera.set_script(FreeFlyCameraScript)
	add_child(camera)
	camera.look_at(Vector3.ZERO)
	camera.current = true
	print("[Godot3DGS-RUST] Raster fixture created: %d Gaussian instances" % resource.point_count)

func _show_compute_fixture(decode_result: Dictionary) -> void:
	var resource := GaussianResourceScript.new()
	var source_label := "2-splat fixture"
	var imported: Resource = load(IMPORTED_TEST_PLY_PATH)
	var imported_gaussian := imported as GaussianResource
	if imported_gaussian != null and imported_gaussian.is_valid():
		resource = imported_gaussian
		source_label = IMPORTED_TEST_PLY_PATH
	else:
		resource.point_count = int(decode_result["point_count"])
		resource.point_data = _make_fixture_splats_immediately_visible(decode_result["point_data"])
		resource.positions = decode_result["positions"]
		resource.aabb = AABB(Vector3(-1.0, -1.0, -1.0), Vector3(2.0, 2.0, 2.0))
	var manager := GaussianRenderManagerScript.new()
	manager.name = "GaussianRenderManager"
	add_child(manager)
	var splat_node := GaussianComputeNodeScript.new()
	splat_node.name = "GaussianComputeFixture"
	splat_node.gaussian = resource
	splat_node.collision_voxel_size = collision_voxel_size
	splat_node.collision_opacity_cutoff = collision_opacity_cutoff
	splat_node.generate_collision_on_ready = generate_collision_on_start
	splat_node.collision_generated.connect(_on_collision_generated)
	add_child(splat_node)
	var compute_effect := GaussianCompositorEffectScript.new()
	compute_effect.display_mode = 1 if direct_texture_diagnostic_mode else 0
	var compositor := Compositor.new()
	compositor.compositor_effects = [compute_effect]
	var environment := Environment.new()
	environment.background_mode = Environment.BG_COLOR
	environment.background_color = Color(0.03, 0.03, 0.05)
	var world_environment := WorldEnvironment.new()
	world_environment.environment = environment
	world_environment.compositor = compositor
	add_child(world_environment)
	var camera := Camera3D.new()
	camera.position = Vector3(0.0, 0.0, 6.0)
	camera.set_script(FreeFlyCameraScript)
	add_child(camera)
	camera.look_at(Vector3.ZERO)
	camera.current = true
	var display_label := "direct-output diagnostic" if direct_texture_diagnostic_mode else "scene compositor"
	print("[Godot3DGS-RUST] Full Compute scene registered: %d GPU splats from %s (%s mode)" % [resource.point_count, source_label, display_label])

func _on_collision_generated(result: Dictionary) -> void:
	if not result.get("ok", false) or not spawn_collision_test_cube:
		return
	_spawn_collision_test_cube()

func _spawn_collision_test_cube() -> void:
	var existing := get_node_or_null("CollisionTestCube") as RigidBody3D
	if existing != null:
		existing.queue_free()

	var body := RigidBody3D.new()
	body.name = "CollisionTestCube"
	body.position = collision_test_cube_position
	body.mass = 1.0
	body.continuous_cd = true
	body.contact_monitor = true
	body.max_contacts_reported = 8
	body.body_entered.connect(_on_test_cube_body_entered)
	add_child(body)

	var box_shape := BoxShape3D.new()
	box_shape.size = Vector3.ONE * collision_test_cube_size
	var collision_shape := CollisionShape3D.new()
	collision_shape.name = "CollisionShape3D"
	collision_shape.shape = box_shape
	body.add_child(collision_shape)

	var box_mesh := BoxMesh.new()
	box_mesh.size = Vector3.ONE * collision_test_cube_size
	var material := StandardMaterial3D.new()
	material.albedo_color = Color(1.0, 0.12, 0.05)
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	box_mesh.material = material
	var mesh_instance := MeshInstance3D.new()
	mesh_instance.name = "VisibleCube"
	mesh_instance.mesh = box_mesh
	body.add_child(mesh_instance)
	print("[Godot3DGS-RUST] Collision test cube spawned at %s" % body.position)

func _on_test_cube_body_entered(other: Node) -> void:
	print("[Godot3DGS-RUST] Collision test cube contacted: %s" % other.name)

func _make_fixture_splats_immediately_visible(raw_data: PackedByteArray) -> PackedByteArray:
	# In the 60-float GPU contract, offset 3 is `time` for the reference
	# renderer's entry animation. Test splats use a time in the past so their
	# first rendered frame is useful for diagnostics.
	var result := raw_data.duplicate()
	for index in range(floori(float(result.size()) / float(GaussianResourceScript.BYTES_PER_SPLAT))):
		result.encode_float(index * GaussianResourceScript.BYTES_PER_SPLAT + 3 * 4, -10.0)
	return result

func _write_milestone_2_fixture() -> String:
	var path := "user://milestone_2_fixture.ply"
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_string("ply\nformat binary_little_endian 1.0\nelement vertex 2\nproperty float x\nproperty float y\nproperty float z\nproperty float f_dc_0\nproperty float f_dc_1\nproperty float f_dc_2\nproperty float opacity\nproperty float scale_0\nproperty float scale_1\nproperty float scale_2\nproperty float rot_0\nproperty float rot_1\nproperty float rot_2\nproperty float rot_3\nend_header\n")
	# Standard 3DGS stores log-scale. -4.0 decodes to about 0.018, which keeps
	# this two-splat fixture inside the renderer's 10 tile-keys-per-splat budget.
	for values in [[1.0, 2.0, 3.0, 0.1, 0.2, 0.3, 0.0, -4.0, -4.0, -4.0, 1.0, 0.0, 0.0, 0.0], [3.0, 4.0, 5.0, 0.4, 0.5, 0.6, 1.0, -4.0, -4.0, -4.0, 1.0, 0.0, 0.0, 0.0]]:
		for value in values:
			file.store_float(value)
	file.close()
	return ProjectSettings.globalize_path(path)
