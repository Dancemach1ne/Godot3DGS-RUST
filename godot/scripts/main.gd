extends Node

const GaussianResourceScript = preload("res://scripts/gaussian_resource.gd")
const GaussianSplatRasterScript = preload("res://scripts/raster/gaussian_splat_raster.gd")
const GaussianRenderManagerScript = preload("res://scripts/compute/full/gaussian_render_manager.gd")
const GaussianComputeNodeScript = preload("res://scripts/compute/full/gaussian_compute_node.gd")
const GaussianCompositorEffectScript = preload("res://scripts/compute/full/gaussian_compositor_effect.gd")
const FreeFlyCameraScript = preload("res://scripts/free_fly_camera.gd")
const IMPORTED_TEST_PLY_PATH := "res://assets/point_cloud.ply"

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
	camera.look_at(Vector3.ZERO)
	camera.set_script(FreeFlyCameraScript)
	add_child(camera)
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
	add_child(splat_node)
	# Milestone 4 diagnostic: display the Compute output texture directly. This
	# distinguishes an empty Compute result from a compositor-blending problem.
	var compute_effect := GaussianCompositorEffectScript.new()
	compute_effect.display_mode = 1 # GaussianCompositorEffect.DisplayMode.DIRECT_TEXTURE
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
	camera.look_at(Vector3.ZERO)
	camera.set_script(FreeFlyCameraScript)
	add_child(camera)
	camera.current = true
	print("[Godot3DGS-RUST] Full Compute scene registered: %d GPU splats from %s (direct-output diagnostic mode)" % [resource.point_count, source_label])

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
